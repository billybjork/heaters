// Fallback Video Player (for older browsers or non-virtual clips)
// Traditional HTML5 video element with frame-accurate seeking support

class FallbackVideoPlayer {
  constructor(clipId, viewerEl, scrubEl, playPauseBtn, frameLblEl, meta, speedBtn) {
    /* element refs */
    this.clipId = clipId;
    this.viewerEl = viewerEl;
    this.scrubEl = scrubEl;
    this.playPauseBtn = playPauseBtn;
    this.frameLblEl = frameLblEl;
    this.speedBtn = speedBtn;

    /* metadata */
    this.meta = meta;

    /* runtime state */
    this.currentFrame = 1;
    this.isPlaying = false;
    this.isScrubbing = false;

    /* playback speeds */
    this.speeds = [0.5, 1, 1.5, 2];
    this.speedIndex = 1;

    /* video element */
    this.video = null;
  }

  async initialize() {
    try {
      await this._setupVideo();
      this._setupUI();
      this._attachEventListeners();
      console.log(`[FallbackVideoPlayer] Initialized for clip ${this.clipId}`);
    } catch (error) {
      console.error("[FallbackVideoPlayer] Initialization failed:", error);
    }
  }

  async _setupVideo() {
    this.video = document.createElement("video");
    this.video.style.width = "100%";
    this.video.style.height = "100%";
    this.video.style.objectFit = "contain";
    this.video.preload = "metadata";
    this.video.muted = true; // Prevent audio during review
    
    // Use appropriate video source
    if (this.meta.isVirtual && this.meta.proxyVideoUrl) {
      this.video.src = this.meta.proxyVideoUrl;
    } else if (this.meta.clipVideoUrl) {
      this.video.src = this.meta.clipVideoUrl;
    }
    
    this.viewerEl.innerHTML = "";
    this.viewerEl.appendChild(this.video);

    // Wait for video to load
    return new Promise((resolve, reject) => {
      this.video.addEventListener("loadedmetadata", resolve);
      this.video.addEventListener("error", reject);
    });
  }

  _setupUI() {
    const m = this.meta;
    let totalFrames, startTime = 0;
    
    if (m.isVirtual && m.cutPoints) {
      // For virtual clips, use cut points to determine frame range
      totalFrames = m.totalFrames || 1;
      startTime = m.cutPoints.start_time_seconds || 0;
      
      // Seek to the start of the virtual clip
      if (this.video && startTime > 0) {
        this.video.currentTime = startTime;
      }
    } else {
      // For physical clips, use video duration
      const duration = this.video.duration || 0;
      const fps = m.fps || 30;
      totalFrames = Math.ceil(duration * fps);
    }

    /* controls default state */
    this.scrubEl.min = 1;
    this.scrubEl.max = Math.max(1, totalFrames - 1);
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
    /* play / pause */
    this._onPlayPause = e => {
      e.stopPropagation();
      this.togglePlayback();
    };
    this.playPauseBtn.addEventListener("click", this._onPlayPause);

    /* scrub bar */
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

    /* speed toggle */
    if (this.speedBtn) {
      this._onSpeedClick = e => {
        e.stopPropagation();
        this._cycleSpeed();
      };
      this.speedBtn.addEventListener("click", this._onSpeedClick);
    }

    /* video time updates */
    this._onTimeUpdate = () => {
      if (!this.isScrubbing) {
        const fps = this.meta.fps || 30;
        let frame;
        
        if (this.meta.isVirtual && this.meta.cutPoints) {
          // For virtual clips, calculate frame relative to clip start
          const startTime = this.meta.cutPoints.start_time_seconds || 0;
          const relativeTime = Math.max(0, this.video.currentTime - startTime);
          frame = Math.floor(relativeTime * fps) + 1;
        } else {
          // For physical clips, use absolute time
          frame = Math.floor(this.video.currentTime * fps) + 1;
        }
        
        this.currentFrame = frame;
        this.frameLblEl.textContent = `Frame: ${frame}`;
        this.scrubEl.value = frame;
      }
    };
    this.video.addEventListener("timeupdate", this._onTimeUpdate);
  }

  async updateFrame(frameNum, force = false) {
    if (!this.video) return;
    
    const fps = this.meta.fps || 30;
    let totalFrames, timeSeconds;
    
    if (this.meta.isVirtual && this.meta.cutPoints) {
      // For virtual clips, use cut points
      totalFrames = this.meta.totalFrames || 1;
      const startTime = this.meta.cutPoints.start_time_seconds || 0;
      
      const f = Math.max(1, Math.min(frameNum, totalFrames - 1));
      if (f === this.currentFrame && !force) return;

      this.currentFrame = f;
      this.frameLblEl.textContent = `Frame: ${f}`;
      if (!this.isScrubbing) this.scrubEl.value = f;

      // Seek to absolute time in source video
      timeSeconds = startTime + (f - 1) / fps;
      this.video.currentTime = timeSeconds;
    } else {
      // For physical clips, use video duration
      const duration = this.video.duration || 0;
      totalFrames = Math.ceil(duration * fps);
      
      const f = Math.max(1, Math.min(frameNum, totalFrames - 1));
      if (f === this.currentFrame && !force) return;

      this.currentFrame = f;
      this.frameLblEl.textContent = `Frame: ${f}`;
      if (!this.isScrubbing) this.scrubEl.value = f;

      // Seek video to frame time
      timeSeconds = (f - 1) / fps;
      this.video.currentTime = timeSeconds;
    }
  }

  _cycleSpeed() {
    this.speedIndex = (this.speedIndex + 1) % this.speeds.length;
    const rate = this.speeds[this.speedIndex];
    this.speedBtn.textContent = `${rate}×`;
    this.video.playbackRate = rate;
  }

  play() {
    if (!this.video || this.isPlaying) return;
    this.isPlaying = true;
    this.playPauseBtn.textContent = "⏸";
    this.video.play();
  }

  pause() {
    if (!this.video || !this.isPlaying) return;
    this.isPlaying = false;
    this.playPauseBtn.textContent = "▶";
    this.video.pause();
  }

  togglePlayback() {
    this.isPlaying ? this.pause() : this.play();
  }

  cleanup() {
    this.pause();
    
    // Clean up event listeners
    this.playPauseBtn.removeEventListener("click", this._onPlayPause);
    this.scrubEl.removeEventListener("mousedown", this._onScrubStart);
    this.scrubEl.removeEventListener("mouseup", this._onScrubEnd);
    this.scrubEl.removeEventListener("input", this._onScrubInput);
    if (this.speedBtn) {
      this.speedBtn.removeEventListener("click", this._onSpeedClick);
    }
    if (this.video) {
      this.video.removeEventListener("timeupdate", this._onTimeUpdate);
    }
  }
}

export { FallbackVideoPlayer };