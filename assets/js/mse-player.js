// MSE-based Video Player for efficient byte-range streaming
// Uses Media Source Extensions instead of WebCodecs

class MSEPlayer {
  constructor(clipId, viewerEl, scrubEl, playPauseBtn, frameLblEl, meta, speedBtn) {
    this.clipId = clipId;
    this.viewerEl = viewerEl;
    this.scrubEl = scrubEl;
    this.playPauseBtn = playPauseBtn;
    this.frameLblEl = frameLblEl;
    this.speedBtn = speedBtn;
    this.meta = meta;

    // State
    this.currentFrame = 1;
    this.isPlaying = false;
    this.playbackInterval = null;
    this.isScrubbing = false;
    this.isInitialized = false;

    // MSE components
    this.video = null;
    this.mediaSource = null;
    this.sourceBuffer = null;
    this.loadedSegments = new Set();

    // Speeds
    this.speeds = [0.5, 1, 1.5, 2];
    this.speedIndex = 1;
  }

  async initialize() {
    try {
      await this._setupVideo();
      await this._setupMSE();
      this._setupUI();
      this._attachEventListeners();
      this.isInitialized = true;
      
      // Load first segment
      await this.updateFrame(1, true);
      console.log(`[MSEPlayer] Initialized for clip ${this.clipId}`);
    } catch (error) {
      console.error("[MSEPlayer] Initialization failed:", error);
      throw error;
    }
  }

  async _setupVideo() {
    this.video = document.createElement("video");
    this.video.style.width = "100%";
    this.video.style.height = "100%";
    this.video.style.objectFit = "contain";
    this.video.controls = false;
    this.video.muted = true;
    this.video.playsInline = true;
    
    this.viewerEl.innerHTML = "";
    this.viewerEl.appendChild(this.video);
  }

  async _setupMSE() {
    return new Promise((resolve, reject) => {
      if (!('MediaSource' in window)) {
        reject(new Error('MediaSource not supported'));
        return;
      }

      this.mediaSource = new MediaSource();
      this.video.src = URL.createObjectURL(this.mediaSource);

      this.mediaSource.addEventListener('sourceopen', async () => {
        console.log('[MSEPlayer] MediaSource opened');
        
        try {
          // Use MP4 codec for H.264 baseline
          this.sourceBuffer = this.mediaSource.addSourceBuffer('video/mp4; codecs="avc1.42E01E"');
          
          this.sourceBuffer.addEventListener('updateend', () => {
            console.log('[MSEPlayer] SourceBuffer update completed');
          });

          this.sourceBuffer.addEventListener('error', (e) => {
            console.error('[MSEPlayer] SourceBuffer error:', e);
            // Log more details about the error
            console.error('[MSEPlayer] SourceBuffer state:', {
              updating: this.sourceBuffer.updating,
              buffered: this.sourceBuffer.buffered.length,
              timestampOffset: this.sourceBuffer.timestampOffset
            });
          });

          // Load initialization segment first
          await this._loadInitializationSegment();
          
          resolve();
        } catch (error) {
          console.error('[MSEPlayer] Failed to create SourceBuffer:', error);
          reject(error);
        }
      });

      this.mediaSource.addEventListener('sourceended', () => {
        console.log('[MSEPlayer] MediaSource ended');
      });

      this.mediaSource.addEventListener('error', (e) => {
        console.error('[MSEPlayer] MediaSource error:', e);
        reject(e);
      });
    });
  }

  async _loadInitializationSegment() {
    try {
      console.log('[MSEPlayer] Loading initialization segment...');
      
      // Load enough data to find ftyp and moov boxes (typically within first 64KB)
      const response = await fetch(this.meta.proxyVideoUrl, {
        headers: {
          "Range": "bytes=0-65535" // 64KB should contain ftyp + moov
        }
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const arrayBuffer = await response.arrayBuffer();
      const initSegment = this._extractInitializationSegment(arrayBuffer);
      
      console.log('[MSEPlayer] Initialization segment extracted:', initSegment.byteLength, 'bytes');
      
      await this._waitForSourceBufferReady();
      this.sourceBuffer.appendBuffer(initSegment);
      
      // Wait for the initialization to complete
      await this._waitForSourceBufferReady();
      
      console.log('[MSEPlayer] Initialization segment appended successfully');
      
    } catch (error) {
      console.error('[MSEPlayer] Failed to load initialization segment:', error);
      throw error; // Don't continue if init fails
    }
  }

  _extractInitializationSegment(buffer) {
    const view = new DataView(buffer);
    let offset = 0;
    let moovEnd = 0;
    
    // Find ftyp and moov boxes
    while (offset < buffer.byteLength - 8) {
      const boxSize = view.getUint32(offset);
      const boxType = new TextDecoder().decode(buffer.slice(offset + 4, offset + 8));
      
      console.log(`[MSEPlayer] Found box: ${boxType} (size: ${boxSize})`);
      
      if (boxType === 'moov') {
        moovEnd = offset + boxSize;
        break;
      }
      
      if (boxSize === 0 || boxSize > buffer.byteLength - offset) break;
      offset += boxSize;
    }
    
    if (moovEnd === 0) {
      throw new Error('moov box not found in initialization data');
    }
    
    // Return buffer up to end of moov box
    return buffer.slice(0, moovEnd);
  }

  async updateFrame(frameNum, force = false) {
    const last = this.meta.totalFrames - 1;
    const f = Math.max(1, Math.min(frameNum, last));
    if (f === this.currentFrame && !force) return;

    this.currentFrame = f;
    this.frameLblEl.textContent = `Frame: ${f}`;
    if (!this.isScrubbing) this.scrubEl.value = f;

    // Seek the video element to the correct time
    const targetTime = (f - 1) / (this.meta.fps || 30);
    
    // Load the segment if we haven't already
    await this._ensureSegmentLoaded(f);
    
    // Seek to the target time
    if (Math.abs(this.video.currentTime - targetTime) > 0.1) {
      this.video.currentTime = targetTime;
      console.log(`[MSEPlayer] Seeking to frame ${f} (time: ${targetTime}s)`);
    }
  }

  async _ensureSegmentLoaded(frameNum) {
    const keyframeOffsets = this.meta.keyframeOffsets || [];
    if (keyframeOffsets.length === 0) {
      console.warn("[MSEPlayer] No keyframe offsets available");
      return;
    }

    // For fragmented MP4, each keyframe starts a new fragment
    // Find the keyframe index for this frame
    const keyframeIndex = frameNum - 1; // Convert to 0-indexed
    
    if (this.loadedSegments.has(keyframeIndex)) {
      return; // Already loaded
    }

    try {
      // Load the complete fragment starting at this keyframe
      const startByte = keyframeOffsets[keyframeIndex];
      if (startByte === undefined) return;
      
      // Find the end of this fragment (start of next fragment or reasonable end)
      const nextFragmentStart = keyframeOffsets[keyframeIndex + 1];
      const endByte = nextFragmentStart ? nextFragmentStart - 1 : startByte + 512 * 1024; // 512KB fallback

      console.log(`[MSEPlayer] Loading fragment ${keyframeIndex} (frame ${frameNum}) from bytes ${startByte}-${endByte}`);

      const response = await fetch(this.meta.proxyVideoUrl, {
        headers: {
          "Range": `bytes=${startByte}-${endByte}`
        }
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const arrayBuffer = await response.arrayBuffer();
      const fragment = this._extractMediaFragment(arrayBuffer);
      
      // Wait for any pending updates to complete
      await this._waitForSourceBufferReady();
      
      // Append the fragment
      this.sourceBuffer.appendBuffer(fragment);
      this.loadedSegments.add(keyframeIndex);

      console.log(`[MSEPlayer] Fragment ${keyframeIndex} loaded (${fragment.byteLength} bytes)`);

    } catch (error) {
      console.error(`[MSEPlayer] Failed to load fragment for frame ${frameNum}:`, error);
    }
  }

  _extractMediaFragment(buffer) {
    // For fragmented MP4, we need to find moof+mdat boxes
    const view = new DataView(buffer);
    let offset = 0;
    let fragmentStart = -1;
    let fragmentEnd = buffer.byteLength;
    
    while (offset < buffer.byteLength - 8) {
      const boxSize = view.getUint32(offset);
      const boxType = new TextDecoder().decode(buffer.slice(offset + 4, offset + 8));
      
      if (boxType === 'moof' && fragmentStart === -1) {
        fragmentStart = offset;
      }
      
      if (boxType === 'mdat' || boxType === 'moof') {
        console.log(`[MSEPlayer] Found fragment box: ${boxType} (size: ${boxSize})`);
      }
      
      if (boxSize === 0 || boxSize > buffer.byteLength - offset) break;
      offset += boxSize;
    }
    
    if (fragmentStart === -1) {
      console.warn('[MSEPlayer] No moof box found, using full buffer');
      return buffer;
    }
    
    return buffer.slice(fragmentStart, fragmentEnd);
  }

  async _waitForSourceBufferReady() {
    return new Promise((resolve) => {
      if (!this.sourceBuffer.updating) {
        resolve();
        return;
      }
      
      const onUpdateEnd = () => {
        this.sourceBuffer.removeEventListener('updateend', onUpdateEnd);
        resolve();
      };
      
      this.sourceBuffer.addEventListener('updateend', onUpdateEnd);
    });
  }

  _setupUI() {
    const m = this.meta;
    this.scrubEl.min = 1;
    this.scrubEl.max = Math.max(1, m.totalFrames - 1);
    this.scrubEl.value = this.currentFrame;
    this.scrubEl.disabled = false;

    this.playPauseBtn.disabled = false;
    this.playPauseBtn.textContent = "▶";
    this.frameLblEl.textContent = `Frame: ${this.currentFrame}`;

    if (this.speedBtn) {
      this.speedBtn.disabled = false;
      this.speedBtn.textContent = `${this.speeds[this.speedIndex]}×`;
    }
  }

  _attachEventListeners() {
    this._onPlayPause = e => {
      e.stopPropagation();
      this.togglePlayback();
    };
    this.playPauseBtn.addEventListener("click", this._onPlayPause);

    this._onScrubStart = () => {
      this.isScrubbing = true;
      if (this.isPlaying) this.pause();
    };
    this._onScrubEnd = () => {
      this.isScrubbing = false;
    };
    this._onScrubInput = e => {
      const f = parseInt(e.target.value, 10);
      this.updateFrame(f, true);
    };
    this.scrubEl.addEventListener("mousedown", this._onScrubStart);
    this.scrubEl.addEventListener("mouseup", this._onScrubEnd);
    this.scrubEl.addEventListener("input", this._onScrubInput);

    if (this.speedBtn) {
      this._onSpeedClick = e => {
        e.stopPropagation();
        this._cycleSpeed();
      };
      this.speedBtn.addEventListener("click", this._onSpeedClick);
    }

    // Video element events
    this.video.addEventListener('timeupdate', () => {
      if (!this.isScrubbing && !this.isPlaying) {
        const frameNum = Math.round(this.video.currentTime * (this.meta.fps || 30)) + 1;
        if (frameNum !== this.currentFrame) {
          this.currentFrame = frameNum;
          this.frameLblEl.textContent = `Frame: ${frameNum}`;
          this.scrubEl.value = frameNum;
        }
      }
    });
  }

  _cycleSpeed() {
    this.speedIndex = (this.speedIndex + 1) % this.speeds.length;
    const rate = this.speeds[this.speedIndex];
    this.speedBtn.textContent = `${rate}×`;
    localStorage.setItem("webCodecsPlayerSpeed", rate.toString());

    this.video.playbackRate = rate;
  }

  play() {
    if (this.isPlaying || !this.isInitialized) return;
    this.isPlaying = true;
    this.playPauseBtn.textContent = "⏸";

    this.video.play().catch(error => {
      console.error('[MSEPlayer] Play failed:', error);
      this.pause();
    });
  }

  pause() {
    if (!this.isPlaying) return;
    this.isPlaying = false;
    this.playPauseBtn.textContent = "▶";
    this.video.pause();
  }

  togglePlayback() {
    this.isPlaying ? this.pause() : this.play();
  }

  cleanup() {
    this.pause();
    
    this.playPauseBtn.removeEventListener("click", this._onPlayPause);
    this.scrubEl.removeEventListener("mousedown", this._onScrubStart);
    this.scrubEl.removeEventListener("mouseup", this._onScrubEnd);
    this.scrubEl.removeEventListener("input", this._onScrubInput);
    if (this.speedBtn) {
      this.speedBtn.removeEventListener("click", this._onSpeedClick);
    }

    if (this.mediaSource && this.mediaSource.readyState === 'open') {
      this.mediaSource.endOfStream();
    }

    if (this.video.src) {
      URL.revokeObjectURL(this.video.src);
    }
  }
}

export { MSEPlayer };