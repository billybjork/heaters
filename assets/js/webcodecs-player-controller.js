// Phoenix LiveView hook for virtual clip review
// Extracted from webcodecs-player.js

import { MSEPlayer } from "./mse-player";
import { FallbackVideoPlayer } from "./fallback-video-player";

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
    const speedBtn = container.querySelector(`#speed-${clipId}`);

    if (!scrub || !playPause || !frameLabel) {
      console.warn("[WebCodecsPlayer] missing controls for clip", clipId);
      return;
    }

    /* detect WebCodecs support and choose player */
    const supportsWebCodecs = this._detectWebCodecsSupport();
    console.log(`[WebCodecsPlayer] WebCodecs support: ${supportsWebCodecs}`);

    /* initialize player with fallback logic */
    this._initializePlayer(supportsWebCodecs, meta, clipId, scrub, playPause, frameLabel, speedBtn);
  },

  async _initializePlayer(supportsWebCodecs, meta, clipId, scrub, playPause, frameLabel, speedBtn) {
    let useWebCodecs = supportsWebCodecs && meta.isVirtual && meta.keyframeOffsets && meta.keyframeOffsets.length > 0;
    
    if (useWebCodecs) {
      try {
        /* attempt to use WebCodecs player for virtual clips with keyframe data */
        console.log(`[WebCodecsPlayer] Attempting WebCodecs player - WebCodecs: ${supportsWebCodecs}, Virtual: ${meta.isVirtual}, Keyframes: ${meta.keyframeOffsets?.length || 0}`);
        this.player = new MSEPlayer(
          clipId,
          this.el,
          scrub,
          playPause,
          frameLabel,
          meta,
          speedBtn
        );
        
        await this.player.initialize();
        console.log(`[WebCodecsPlayer] WebCodecs player initialized successfully`);
      } catch (error) {
        console.warn(`[WebCodecsPlayer] WebCodecs initialization failed, falling back to traditional player:`, error);
        useWebCodecs = false;
      }
    }
    
    if (!useWebCodecs) {
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
      await this.player.initialize();
    }

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
    };
    window.addEventListener("keydown", this._onKey);
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