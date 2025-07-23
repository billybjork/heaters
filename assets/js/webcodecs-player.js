/**
 * WebCodecs-based Video Player for Virtual Clips
 * ──────────────────────────────────────────────────────────────────────────
 * • WebCodecsPlayerController – Phoenix hook for virtual clip review
 * • WebCodecsPlayer           – core WebCodecs playback with frame seeking
 * • FallbackVideoPlayer       – traditional <video> fallback for older browsers
 *
 * Uses keyframe offsets for frame-perfect seeking on review proxy videos.
 * Automatic fallback to <video> element when WebCodecs is unavailable.
 */

import { SplitManager } from "./split-manager";

/* ────────────────────────────────────────────────────────────────────────── */
/*  Phoenix Hook – WebCodecs player controller                               */
/* ────────────────────────────────────────────────────────────────────────── */

export const WebCodecsPlayerController = {
  mounted() {
    const clipId = this.el.dataset.clipId;
    const playerData = this.el.dataset.player;
    if (!playerData) {
      console.warn("[WebCodecsPlayer] missing data-player", this.el);
      return;
    }

    let meta;
    try {
      meta = JSON.parse(playerData);
    } catch (err) {
      console.error("[WebCodecsPlayer] invalid JSON in data-player", err);
      return;
    }
    if (!meta.isValid) {
      console.error("[WebCodecsPlayer] meta not valid", meta);
      return;
    }

    /* collect control elements */
    const container = this.el.parentElement;
    const scrub = container.querySelector(`#scrub-${clipId}`);
    const playPause = container.querySelector(`#playpause-${clipId}`);
    const frameLabel = container.querySelector(`#frame-display-${clipId}`);
    const splitBtn = document.getElementById(`split-${clipId}`);
    const speedBtn = container.querySelector(`#speed-${clipId}`);

    if (!scrub || !playPause || !frameLabel) {
      console.warn("[WebCodecsPlayer] missing controls for clip", clipId);
      return;
    }

    /* detect WebCodecs support and choose player */
    const supportsWebCodecs = this._detectWebCodecsSupport();
    console.log(`[WebCodecsPlayer] WebCodecs support: ${supportsWebCodecs}`);

    if (supportsWebCodecs && meta.isVirtual && meta.keyframeOffsets && meta.keyframeOffsets.length > 0) {
      /* use WebCodecs player for virtual clips with keyframe data */
      this.player = new WebCodecsPlayer(
        clipId,
        this.el,
        scrub,
        playPause,
        frameLabel,
        meta,
        speedBtn
      );
    } else {
      /* fallback to traditional video player */
      console.log(`[WebCodecsPlayer] Using fallback player - WebCodecs: ${supportsWebCodecs}, Virtual: ${meta.isVirtual}, Keyframes: ${meta.keyframeOffsets?.length || 0}`);
      this.player = new FallbackVideoPlayer(
        clipId,
        this.el,
        scrub,
        playPause,
        frameLabel,
        meta,
        speedBtn
      );
    }

    /* Split-button */
    splitBtn?.addEventListener("click", () => {
      if (!SplitManager.splitMode) {
        SplitManager.enter(this.player, splitBtn);
      } else {
        SplitManager.commit((evt, payload) => this.pushEvent(evt, payload));
      }
    });

    /* Click on player area toggles play/pause */
    this._onViewerClick = () => this.player.togglePlayback();
    this.el.addEventListener("click", this._onViewerClick);

    /* Global keyboard shortcuts */
    this._onKey = evt => {
      /* Space (plain) → play/pause toggle */
      if (evt.code === "Space" && !evt.shiftKey && !evt.metaKey && !evt.ctrlKey) {
        evt.preventDefault();
        this.player.togglePlayback();
        return;
      }

      /* Arrow keys drive split mode */
      if (evt.key === "ArrowLeft" || evt.key === "ArrowRight") {
        evt.preventDefault();
        if (!SplitManager.splitMode) SplitManager.enter(this.player, splitBtn);
        SplitManager.nudge(evt.key === "ArrowLeft" ? -1 : +1);
        return;
      }

      if (evt.key === "Escape") SplitManager.exit();
    };
    window.addEventListener("keydown", this._onKey);

    /* initialize player */
    this.player.initialize();
  },

  updated() {
    if (this.player) this.player.cleanup();
    this.mounted(); // re-init on DOM patch
  },

  destroyed() {
    this.player?.cleanup();
    this.el.removeEventListener("click", this._onViewerClick);
    window.removeEventListener("keydown", this._onKey);
  },

  _detectWebCodecsSupport() {
    return (
      typeof window !== "undefined" &&
      "VideoDecoder" in window &&
      "VideoFrame" in window &&
      "EncodedVideoChunk" in window
    );
  }
};

/* ────────────────────────────────────────────────────────────────────────── */
/*  WebCodecs-based Video Player (for virtual clips)                        */
/* ────────────────────────────────────────────────────────────────────────── */

class WebCodecsPlayer {
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
    // Frame indexing: Frontend uses 1-indexed frames (1 to clip_total_frames-1)
    this.currentFrame = 1; // start from frame 1
    this.isPlaying = false;
    this.playbackInterval = null;
    this.isScrubbing = false;

    /* playback speeds */
    this.speeds = [0.5, 1, 1.5, 2];
    this.speedIndex = 1; // Default to 1x speed

    // Load speed from localStorage
    const savedSpeed = localStorage.getItem("webCodecsPlayerSpeed");
    if (savedSpeed) {
      const parsedSpeed = parseFloat(savedSpeed);
      const savedSpeedIndex = this.speeds.indexOf(parsedSpeed);
      if (savedSpeedIndex !== -1) {
        this.speedIndex = savedSpeedIndex;
      }
    }

    /* WebCodecs components */
    this.decoder = null;
    this.frameBuffer = new Map(); // frameNumber -> VideoFrame
    this.canvas = null;
    this.canvasCtx = null;
    this.fetchController = null;

    /* seeking state */
    this.pendingSeek = null;
    this.isInitialized = false;
  }

  /* WebCodecs initialization ------------------------------------------- */
  async initialize() {
    try {
      await this._setupCanvas();
      await this._setupDecoder();
      await this._loadInitialFrames();
      this._setupUI();
      this._attachEventListeners();
      this.isInitialized = true;
      
      // Show first frame
      await this.updateFrame(1, true);
      console.log(`[WebCodecsPlayer] Initialized for clip ${this.clipId}`);
    } catch (error) {
      console.error("[WebCodecsPlayer] Initialization failed:", error);
      // Could fallback to traditional player here
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
    if (!this.meta.proxyVideoUrl) {
      throw new Error("No proxy video URL available");
    }

    this.decoder = new VideoDecoder({
      output: (frame) => this._onDecodedFrame(frame),
      error: (error) => console.error("[WebCodecsPlayer] Decoder error:", error)
    });

    // Configure decoder (H.264 for our all-I-frame proxy)
    const config = {
      codec: "avc1.42E01E", // H.264 baseline profile
      optimizeForLatency: true
    };

    this.decoder.configure(config);
  }

  async _loadInitialFrames() {
    // Load keyframes using byte-range requests
    const keyframeOffsets = this.meta.keyframeOffsets || [];
    
    if (keyframeOffsets.length === 0) {
      // Fallback: Load first chunk of video without keyframe data
      console.warn("[WebCodecsPlayer] No keyframe offsets available, using fallback loading");
      await this._loadVideoChunk(0, 2 * 1024 * 1024); // Load first 2MB
      return;
    }
    
    // Load the first few keyframes to get started
    const initialFramesToLoad = Math.min(10, keyframeOffsets.length);
    for (let i = 0; i < initialFramesToLoad; i++) {
      await this._loadKeyframe(i);
    }
  }

  async _loadVideoChunk(startByte, size) {
    try {
      const endByte = startByte + size - 1;
      const response = await fetch(this.meta.proxyVideoUrl, {
        headers: {
          "Range": `bytes=${startByte}-${endByte}`
        }
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const arrayBuffer = await response.arrayBuffer();
      const chunk = new EncodedVideoChunk({
        type: "key", // All-I-frame means every chunk can be a keyframe
        timestamp: 0, // Start from beginning
        data: arrayBuffer
      });

      this.decoder.decode(chunk);
    } catch (error) {
      console.error(`[WebCodecsPlayer] Failed to load video chunk:`, error);
    }
  }

  async _loadKeyframe(keyframeIndex) {
    const offsets = this.meta.keyframeOffsets || [];
    if (keyframeIndex >= offsets.length) return;

    const startByte = offsets[keyframeIndex];
    const endByte = offsets[keyframeIndex + 1] || startByte + 1024 * 1024; // 1MB default chunk

    try {
      const response = await fetch(this.meta.proxyVideoUrl, {
        headers: {
          "Range": `bytes=${startByte}-${endByte - 1}`
        }
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const arrayBuffer = await response.arrayBuffer();
      const chunk = new EncodedVideoChunk({
        type: keyframeIndex === 0 ? "key" : "delta",
        timestamp: keyframeIndex * (1000000 / this.meta.fps), // microseconds
        data: arrayBuffer
      });

      this.decoder.decode(chunk);
    } catch (error) {
      console.error(`[WebCodecsPlayer] Failed to load keyframe ${keyframeIndex}:`, error);
    }
  }

  _onDecodedFrame(frame) {
    // Calculate which logical frame this represents
    const frameNumber = Math.round(frame.timestamp * this.meta.fps / 1000000) + 1;
    
    // Store frame in buffer
    this.frameBuffer.set(frameNumber, frame);
    
    // If this is the current frame, display it
    if (frameNumber === this.currentFrame) {
      this._displayFrame(frame);
    }

    // Clean up old frames to prevent memory leaks
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

    // Resize canvas to match frame dimensions
    this.canvas.width = frame.displayWidth;
    this.canvas.height = frame.displayHeight;

    // Draw frame to canvas
    this.canvasCtx.drawImage(frame, 0, 0);
  }

  /* UI setup and controls ---------------------------------------------- */
  _setupUI() {
    const m = this.meta;

    /* controls default state */
    this.scrubEl.min = 1;
    this.scrubEl.max = Math.max(1, m.totalFrames - 1);
    this.scrubEl.value = this.currentFrame;
    this.scrubEl.disabled = false;

    this.playPauseBtn.disabled = false;
    this.playPauseBtn.textContent = "▶";

    this.frameLblEl.textContent = `Frame: ${this.currentFrame}`;

    /* enable & label the speed button */
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
      if (this.isPlaying) this.pause("scrubStart");
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
  }

  /* Public API --------------------------------------------------------- */

  /** jump to frame N with WebCodecs seeking. */
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

    // Need to seek to this frame
    await this._seekToFrame(f);
  }

  async _seekToFrame(frameNum) {
    const keyframeOffsets = this.meta.keyframeOffsets || [];
    
    if (keyframeOffsets.length === 0) {
      // Fallback: Load video chunk based on estimated byte position
      const frameRate = this.meta.fps || 30;
      const totalFrames = this.meta.totalFrames || 1;
      const estimatedBytesPerFrame = (2 * 1024 * 1024) / totalFrames; // Rough estimate
      const startByte = Math.floor((frameNum - 1) * estimatedBytesPerFrame);
      await this._loadVideoChunk(startByte, 1024 * 1024); // Load 1MB chunk
      return;
    }
    
    // Calculate which keyframe we need
    const frameRate = this.meta.fps || 30;
    const keyframeInterval = 30; // All-I-frame means every frame is a keyframe!
    const keyframeIndex = Math.floor((frameNum - 1) / keyframeInterval);
    
    // For all-I-frame video, we can seek directly to any frame
    await this._loadKeyframe(keyframeIndex);
  }

  /** cycle through playback speeds */
  _cycleSpeed() {
    this.speedIndex = (this.speedIndex + 1) % this.speeds.length;
    const rate = this.speeds[this.speedIndex];
    this.speedBtn.textContent = `${rate}×`;

    // Save speed to localStorage
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

    /* account for speed multiplier */
    const fps = this.meta.fps || 30;
    const interval = 1000 / (fps * this.speeds[this.speedIndex]);
    const last = this.meta.totalFrames - 1;
    
    this.playbackInterval = setInterval(() => {
      const nxt = (this.currentFrame + 1 > last) ? 1 : this.currentFrame + 1;
      this.updateFrame(nxt, true);
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

  /** clean up WebCodecs resources for LV patch / teardown. */
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

    // Clean up WebCodecs resources
    if (this.decoder) {
      this.decoder.close();
      this.decoder = null;
    }

    // Clean up frame buffer
    this.frameBuffer.forEach(frame => frame.close());
    this.frameBuffer.clear();

    // Cancel any pending fetches
    if (this.fetchController) {
      this.fetchController.abort();
    }
  }
}

/* ────────────────────────────────────────────────────────────────────────── */
/*  Fallback Video Player (for older browsers or non-virtual clips)         */
/* ────────────────────────────────────────────────────────────────────────── */

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

export { WebCodecsPlayer, FallbackVideoPlayer }; 