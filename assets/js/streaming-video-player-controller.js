/**
 * Phoenix LiveView Hook for Streaming Video Player
 * 
 * Integrates the StreamingVideoPlayer with Phoenix LiveView.
 * Handles initialization, data updates, and cleanup for both tiny-file
 * virtual clips and direct S3 file playback.
 */

import { StreamingVideoPlayer } from "./streaming-video-player";

export const StreamingVideoPlayerController = {
  mounted() {
    console.log("[StreamingVideoPlayerController] Mounted");

    const videoElement = this.el;
    const videoUrl = videoElement.dataset.videoUrl;
    const playerType = videoElement.dataset.playerType;
    const clipInfoJson = videoElement.dataset.clipInfo;

    // Parse clip information
    let clipInfo = {};
    try {
      if (clipInfoJson) {
        clipInfo = JSON.parse(clipInfoJson);
      }
    } catch (error) {
      console.error("[StreamingVideoPlayerController] Failed to parse clip info:", error);
    }

    console.log(`[StreamingVideoPlayerController] Initializing ${playerType} player with URL: ${videoUrl}`);
    console.log(`[StreamingVideoPlayerController] Clip info:`, clipInfo);

    // Create the player instance
    this.player = new StreamingVideoPlayer(videoElement, {
      controls: true,
      preload: 'metadata',
      showLoadingSpinner: true
    });

    // Load the video if URL is provided
    if (videoUrl) {
      this.player.loadVideo(videoUrl, playerType, clipInfo).catch(error => {
        console.error("[StreamingVideoPlayerController] Failed to load video:", error);
      });
    }

    // Store current state for comparison on updates
    this.currentVideoUrl = videoUrl;
    this.currentPlayerType = playerType;
  },

  updated() {
    console.log("[StreamingVideoPlayerController] Updated");
    console.log("[StreamingVideoPlayerController] Element ID:", this.el.id);
    console.log("[StreamingVideoPlayerController] Player exists:", !!this.player);

    if (!this.player) {
      console.warn("[StreamingVideoPlayerController] Player not initialized on update - component was likely recreated");
      return;
    }

    const videoElement = this.el;
    const videoUrl = videoElement.dataset.videoUrl;
    const playerType = videoElement.dataset.playerType;
    const clipInfoJson = videoElement.dataset.clipInfo;

    // Parse updated clip information
    let clipInfo = {};
    try {
      if (clipInfoJson) {
        clipInfo = JSON.parse(clipInfoJson);
      }
    } catch (error) {
      console.error("[StreamingVideoPlayerController] Failed to parse updated clip info:", error);
    }

    // Check if video URL or player type changed
    const urlChanged = videoUrl && videoUrl !== this.currentVideoUrl;
    const typeChanged = playerType && playerType !== this.currentPlayerType;

    if (urlChanged || typeChanged) {
      console.log(`[StreamingVideoPlayerController] Switching to new clip: ${videoUrl} (${playerType})`);

      this.currentVideoUrl = videoUrl;
      this.currentPlayerType = playerType;

      // Use switchClip for smooth transitions between clips
      this.player.switchClip(videoUrl, playerType, clipInfo).catch(error => {
        console.error("[StreamingVideoPlayerController] Failed to switch to new clip:", error);
      });
    }
  },

  destroyed() {
    console.log("[StreamingVideoPlayerController] Destroyed");

    if (this.player) {
      this.player.destroy();
      this.player = null;
    }

    this.currentVideoUrl = null;
    this.currentPlayerType = null;
  }
};