/**
 * Phoenix LiveView Hook for CloudFront Video Player
 * 
 * Integrates the CloudFrontVideoPlayer with Phoenix LiveView.
 * Handles initialization, data updates, and cleanup.
 */

import { CloudFrontVideoPlayer } from "./cloudfront-video-player";

export const CloudFrontVideoPlayerController = {
  mounted() {
    console.log("[CloudFrontVideoPlayerController] Mounted");
    
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
      console.error("[CloudFrontVideoPlayerController] Failed to parse clip info:", error);
    }
    
    console.log(`[CloudFrontVideoPlayerController] Initializing ${playerType} player with URL: ${videoUrl}`);
    console.log(`[CloudFrontVideoPlayerController] Clip info:`, clipInfo);
    
    // Create the player instance
    this.player = new CloudFrontVideoPlayer(videoElement, {
      controls: true,
      preload: 'metadata'
    });
    
    // Load the video
    if (videoUrl) {
      this.player.loadVideo(videoUrl, clipInfo).catch(error => {
        console.error("[CloudFrontVideoPlayerController] Failed to load video:", error);
      });
    }
  },

  updated() {
    console.log("[CloudFrontVideoPlayerController] Updated");
    
    if (!this.player) {
      console.warn("[CloudFrontVideoPlayerController] Player not initialized on update");
      return;
    }
    
    const videoElement = this.el;
    const videoUrl = videoElement.dataset.videoUrl;
    const clipInfoJson = videoElement.dataset.clipInfo;
    
    // Parse updated clip information
    let clipInfo = {};
    try {
      if (clipInfoJson) {
        clipInfo = JSON.parse(clipInfoJson);
      }
    } catch (error) {
      console.error("[CloudFrontVideoPlayerController] Failed to parse updated clip info:", error);
    }
    
    // Load new video if URL changed
    if (videoUrl && videoUrl !== this.currentVideoUrl) {
      console.log(`[CloudFrontVideoPlayerController] Loading new video: ${videoUrl}`);
      this.currentVideoUrl = videoUrl;
      
      this.player.loadVideo(videoUrl, clipInfo).catch(error => {
        console.error("[CloudFrontVideoPlayerController] Failed to load updated video:", error);
      });
    }
  },

  destroyed() {
    console.log("[CloudFrontVideoPlayerController] Destroyed");
    
    if (this.player) {
      this.player.destroy();
      this.player = null;
    }
    
    this.currentVideoUrl = null;
  }
};