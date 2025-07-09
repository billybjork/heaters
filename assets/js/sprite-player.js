/**
 * Sprite-sheet utilities for Clip Review
 * ──────────────────────────────────────────────────────────────────────────
 * • SpritePlayerController  – full scrubbable viewer in the main panel
 * • SpritePlayer            – core sprite playback functionality
 *
 * No server round-trips: everything runs in the browser.
 */

import { SplitManager } from "./split-manager";

/* ────────────────────────────────────────────────────────────────────────── */
/*  Phoenix Hook – full sprite player                                       */
/* ────────────────────────────────────────────────────────────────────────── */

export const SpritePlayerController = {
  mounted() {
    const clipId = this.el.dataset.clipId;
    const playerData = this.el.dataset.player;
    if (!playerData) {
      console.warn("[SpritePlayer] missing data-player", this.el);
      return;
    }

    let meta;
    try {
      meta = JSON.parse(playerData);
    } catch (err) {
      console.error("[SpritePlayer] invalid JSON in data-player", err);
      return;
    }
    if (!meta.isValid) {
      console.error("[SpritePlayer] meta not valid", meta);
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
      console.warn("[SpritePlayer] missing controls for clip", clipId);
      return;
    }

    /* instantiate player */
    this.player = new SpritePlayer(
      clipId,
      this.el,
      scrub,
      playPause,
      frameLabel,
      meta,
      speedBtn
    );

    /* Split-button */
    splitBtn?.addEventListener("click", () => {
      if (!SplitManager.splitMode) {
        SplitManager.enter(this.player, splitBtn);
      } else {
        SplitManager.commit((evt, payload) => this.pushEvent(evt, payload));
      }
    });

    /* Click on sprite area toggles play/pause */
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

    /* kick off playback */
    this.player.preloadAndPlay();
  },

  updated() {
    if (this.player) this.player.cleanup();
    this.mounted(); // re-init on DOM patch
  },

  destroyed() {
    this.player?.cleanup();
    this.el.removeEventListener("click", this._onViewerClick);
    window.removeEventListener("keydown", this._onKey);
  }
};


/* ────────────────────────────────────────────────────────────────────────── */
/*  Minimal sprite-sheet "video" player (used by main panel)                */
/* ────────────────────────────────────────────────────────────────────────── */

class SpritePlayer {
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
    this.currentFrame = 1; // avoid padding pixel in frame 0
    this.isPlaying = false;
    this.playbackInterval = null;
    this.isScrubbing = false;

    /* playback speeds */
    this.speeds = [1, 1.5, 2];
    this.speedIndex = 0; // Default speed index

    // Load speed from localStorage
    const savedSpeed = localStorage.getItem("spritePlayerSpeed");
    if (savedSpeed) {
      const parsedSpeed = parseFloat(savedSpeed);
      const savedSpeedIndex = this.speeds.indexOf(parsedSpeed);
      if (savedSpeedIndex !== -1) {
        this.speedIndex = savedSpeedIndex;
      }
    }

    /* preload sprite PNG */
    this.spriteImage = new Image();
    this.spriteImage.src = meta.spriteUrl;

    this._setupUI();
    this._attachEventListeners();
  }

  /* initialise DOM attributes ------------------------------------------ */
  _setupUI() {
    const m = this.meta;

    /* viewer background – gigantic sheet of tiles */
    Object.assign(this.viewerEl.style, {
      backgroundImage: `url('${m.spriteUrl}')`,
      backgroundSize: `${m.cols * m.tile_width}px ${m.rows * m.tile_height_calculated}px`,
      width: `${m.tile_width}px`,
      height: `${m.tile_height_calculated}px`,
      backgroundRepeat: "no-repeat",
      backgroundPosition: "0 0"
    });

    /* controls default state */
    this.scrubEl.min = 1;
    this.scrubEl.max = Math.max(1, m.clip_total_frames - 1);
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

  /* event listeners ----------------------------------------------------- */
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

  /* public API ---------------------------------------------------------- */

  /** preload sprite then commence autoplay. */
  preloadAndPlay() {
    if (this.spriteImage.complete) {
      this.play("mounted");
    } else {
      this.spriteImage.onload = () => this.play("preload");
    }
  }

  /** jump to frame N (clamped). */
  updateFrame(frameNum, force = false) {
    const last = this.meta.clip_total_frames - 1;
    const f = Math.max(1, Math.min(frameNum, last));
    if (f === this.currentFrame && !force) return;

    this.currentFrame = f;

    const { bgX, bgY } = this._bgPosForFrame(f);
    this.viewerEl.style.backgroundPosition = `${bgX}px ${bgY}px`;

    this.frameLblEl.textContent = `Frame: ${f}`;
    if (!this.isScrubbing) this.scrubEl.value = f;
  }

  /** cycle through playback speeds */
  _cycleSpeed() {
    this.speedIndex = (this.speedIndex + 1) % this.speeds.length;
    const rate = this.speeds[this.speedIndex];
    this.speedBtn.textContent = `${rate}×`;

    // Save speed to localStorage
    localStorage.setItem("spritePlayerSpeed", rate.toString());

    if (this.isPlaying) {
      this.pause();
      this.play();
    }
  }

  play() {
    if (this.isPlaying || this.meta.clip_fps <= 0) return;
    this.isPlaying = true;
    this.playPauseBtn.textContent = "⏸";

    /* account for speed multiplier */
    const interval = 1000 / (this.meta.clip_fps * this.speeds[this.speedIndex]);
    const last = this.meta.clip_total_frames - 1;
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

  /** clean up DOM listeners for LV patch / teardown. */
  cleanup() {
    this.pause();
    this.playPauseBtn.removeEventListener("click", this._onPlayPause);
    this.scrubEl.removeEventListener("mousedown", this._onScrubStart);
    this.scrubEl.removeEventListener("mouseup", this._onScrubEnd);
    this.scrubEl.removeEventListener("input", this._onScrubInput);
    if (this.speedBtn) {
      this.speedBtn.removeEventListener("click", this._onSpeedClick);
    }
  }

  /* internals ----------------------------------------------------------- */

  /** calculate CSS background offset for a given frame. */
  _bgPosForFrame(frameNum) {
    const m = this.meta;
    const spriteFrames = m.total_sprite_frames;

    const prop = (spriteFrames > 1)
      ? frameNum / (m.clip_total_frames - 1)
      : 0;
    const index = Math.floor(prop * (spriteFrames - 1));

    const col = index % m.cols;
    const row = Math.floor(index / m.cols);

    return {
      bgX: -(col * m.tile_width),
      bgY: -(row * m.tile_height_calculated)
    };
  }
}

export { SpritePlayer };