// Simple WebCodecs-based Video Player
// Uses standard MP4 demuxing instead of raw frame data parsing

class SimpleWebCodecsPlayer {
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

    // WebCodecs
    this.decoder = null;
    this.frameBuffer = new Map();
    this.canvas = null;
    this.canvasCtx = null;

    // Speeds
    this.speeds = [0.5, 1, 1.5, 2];
    this.speedIndex = 1;
  }

  async initialize() {
    try {
      await this._setupCanvas();
      await this._setupDecoder();
      this._setupUI();
      this._attachEventListeners();
      this.isInitialized = true;
      
      // Load first frame
      await this.updateFrame(1, true);
      console.log(`[SimpleWebCodecsPlayer] Initialized for clip ${this.clipId}`);
    } catch (error) {
      console.error("[SimpleWebCodecsPlayer] Initialization failed:", error);
      throw error;
    }
  }

  async _setupCanvas() {
    this.canvas = document.createElement("canvas");
    this.canvas.style.width = "100%";
    this.canvas.style.height = "100%";
    this.canvas.style.objectFit = "contain";
    this.canvas.style.backgroundColor = "#000";
    
    this.viewerEl.innerHTML = "";
    this.viewerEl.appendChild(this.canvas);
    
    this.canvasCtx = this.canvas.getContext("2d");
  }

  async _setupDecoder() {
    this.decoder = new VideoDecoder({
      output: (frame) => {
        console.log("[SimpleWebCodecsPlayer] Frame decoded:", frame.timestamp);
        this._onDecodedFrame(frame);
      },
      error: (error) => {
        console.error("[SimpleWebCodecsPlayer] Decoder error:", error);
      }
    });

    // Use simple baseline H.264 configuration
    const config = {
      codec: "avc1.42E01E", // H.264 baseline profile
      optimizeForLatency: true
    };

    console.log("[SimpleWebCodecsPlayer] Configuring decoder...");
    this.decoder.configure(config);
  }

  async updateFrame(frameNum, force = false) {
    const last = this.meta.totalFrames - 1;
    const f = Math.max(1, Math.min(frameNum, last));
    if (f === this.currentFrame && !force) return;

    this.currentFrame = f;
    this.frameLblEl.textContent = `Frame: ${f}`;
    if (!this.isScrubbing) this.scrubEl.value = f;

    // Check if frame is already in buffer
    const bufferedFrame = this.frameBuffer.get(f);
    if (bufferedFrame) {
      this._displayFrame(bufferedFrame);
      return;
    }

    // Load the frame
    await this._loadFrame(f);
  }

  async _loadFrame(frameNum) {
    const keyframeOffsets = this.meta.keyframeOffsets || [];
    if (keyframeOffsets.length === 0) {
      console.warn("[SimpleWebCodecsPlayer] No keyframe offsets available");
      return;
    }

    // For all-I-frame video, each keyframe offset corresponds to one frame
    const keyframeIndex = frameNum - 1; // Convert to 0-indexed
    if (keyframeIndex >= keyframeOffsets.length) return;

    const startByte = keyframeOffsets[keyframeIndex];
    const endByte = keyframeOffsets[keyframeIndex + 1] || startByte + 64 * 1024;

    try {
      console.log(`[SimpleWebCodecsPlayer] Loading frame ${frameNum} from bytes ${startByte}-${endByte}`);
      
      const response = await fetch(this.meta.proxyVideoUrl, {
        headers: {
          "Range": `bytes=${startByte}-${endByte - 1}`
        }
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const arrayBuffer = await response.arrayBuffer();
      
      // For fragmented MP4, we should be able to decode this directly
      const chunk = new EncodedVideoChunk({
        type: "key", // All frames are keyframes
        timestamp: (frameNum - 1) * (1000000 / (this.meta.fps || 30)),
        data: arrayBuffer
      });

      console.log(`[SimpleWebCodecsPlayer] Decoding chunk for frame ${frameNum}`);
      this.decoder.decode(chunk);

    } catch (error) {
      console.error(`[SimpleWebCodecsPlayer] Failed to load frame ${frameNum}:`, error);
    }
  }

  _onDecodedFrame(frame) {
    const frameNumber = Math.round(frame.timestamp * (this.meta.fps || 30) / 1000000) + 1;
    
    console.log(`[SimpleWebCodecsPlayer] Frame ${frameNumber} decoded`);
    
    // Store frame in buffer
    this.frameBuffer.set(frameNumber, frame);
    
    // If this is the current frame, display it
    if (frameNumber === this.currentFrame) {
      this._displayFrame(frame);
    }

    // Clean up old frames
    if (this.frameBuffer.size > 50) {
      const oldFrames = Array.from(this.frameBuffer.keys())
        .sort((a, b) => a - b)
        .slice(0, -30);
      
      oldFrames.forEach(frameNum => {
        const frame = this.frameBuffer.get(frameNum);
        if (frame) {
          frame.close();
          this.frameBuffer.delete(frameNum);
        }
      });
    }
  }

  _displayFrame(frame) {
    if (!this.canvas || !this.canvasCtx) return;

    try {
      this.canvas.width = frame.displayWidth;
      this.canvas.height = frame.displayHeight;
      this.canvasCtx.drawImage(frame, 0, 0);
      console.log(`[SimpleWebCodecsPlayer] Frame displayed: ${frame.displayWidth}x${frame.displayHeight}`);
    } catch (error) {
      console.error(`[SimpleWebCodecsPlayer] Error drawing frame:`, error);
    }
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
  }

  _cycleSpeed() {
    this.speedIndex = (this.speedIndex + 1) % this.speeds.length;
    const rate = this.speeds[this.speedIndex];
    this.speedBtn.textContent = `${rate}×`;
    localStorage.setItem("webCodecsPlayerSpeed", rate.toString());

    if (this.isPlaying) {
      this.pause();
      this.play();
    }
  }

  play() {
    if (this.isPlaying || !this.isInitialized) return;
    this.isPlaying = true;
    this.playPauseBtn.textContent = "⏸";

    const fps = this.meta.fps || 30;
    const interval = 1000 / (fps * this.speeds[this.speedIndex]);
    const last = this.meta.totalFrames - 1;
    
    this.playbackInterval = setInterval(() => {
      const next = (this.currentFrame + 1 > last) ? 1 : this.currentFrame + 1;
      this.updateFrame(next, true);
    }, interval);
  }

  pause() {
    if (!this.isPlaying) return;
    this.isPlaying = false;
    this.playPauseBtn.textContent = "▶";
    clearInterval(this.playbackInterval);
    this.playbackInterval = null;
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

    if (this.decoder) {
      this.decoder.close();
      this.decoder = null;
    }

    this.frameBuffer.forEach(frame => frame.close());
    this.frameBuffer.clear();
  }
}

export { SimpleWebCodecsPlayer };