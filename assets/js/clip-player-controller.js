/**
 * Phoenix LiveView Hook for Clip Player
 * 
 * Integrates the ClipPlayer with Phoenix LiveView.
 * Handles initialization, data updates, and cleanup for both virtual clips
 * (on-demand generated) and physical clips (direct files).
 */

import { ClipPlayer } from "./clip-player";

export const ClipPlayerController = {
    mounted() {
        console.log("[ClipPlayerController] Mounted");

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
            console.error("[ClipPlayerController] Failed to parse clip info:", error);
        }

        console.log(`[ClipPlayerController] Initializing ${playerType} player with URL: ${videoUrl}`);
        console.log(`[ClipPlayerController] Clip info:`, clipInfo);

        // Create the player instance
        this.player = new ClipPlayer(videoElement, {
            controls: true,
            preload: 'metadata',
            showLoadingSpinner: true
        });

        // Load the video if URL is provided
        if (videoUrl) {
            this.player.loadVideo(videoUrl, playerType, clipInfo).catch(error => {
                console.error("[ClipPlayerController] Failed to load video:", error);
            });
        }

        // Store current state for comparison on updates
        this.currentVideoUrl = videoUrl;
        this.currentPlayerType = playerType;
    },

    updated() {
        console.log("[ClipPlayerController] Updated");
        console.log("[ClipPlayerController] Element ID:", this.el.id);
        console.log("[ClipPlayerController] Player exists:", !!this.player);

        if (!this.player) {
            console.warn("[ClipPlayerController] Player not initialized on update - component was likely recreated");
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
            console.error("[ClipPlayerController] Failed to parse updated clip info:", error);
        }

        // Check if video URL or player type changed
        const urlChanged = videoUrl && videoUrl !== this.currentVideoUrl;
        const typeChanged = playerType && playerType !== this.currentPlayerType;

        if (urlChanged || typeChanged) {
            console.log(`[ClipPlayerController] Switching to new clip: ${videoUrl} (${playerType})`);

            this.currentVideoUrl = videoUrl;
            this.currentPlayerType = playerType;

            // Use switchClip for smooth transitions between clips
            this.player.switchClip(videoUrl, playerType, clipInfo).catch(error => {
                console.error("[ClipPlayerController] Failed to switch to new clip:", error);
            });
        }
    },

    destroyed() {
        console.log("[ClipPlayerController] Destroyed");

        if (this.player) {
            this.player.destroy();
            this.player = null;
        }

        this.currentVideoUrl = null;
        this.currentPlayerType = null;
    }
};