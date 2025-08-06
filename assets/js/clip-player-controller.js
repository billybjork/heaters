/**
 * Phoenix LiveView Hook for Clip Player
 * 
 * Integrates the ClipPlayer with Phoenix LiveView.
 * Handles initialization, data updates, and cleanup for clips in different stages:
 * temp clips (on-demand generated) and exported clips (direct files).
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

        // Load the video if URL is provided, otherwise show loading state
        if (videoUrl) {
            this.player.loadVideo(videoUrl, playerType, clipInfo).catch(error => {
                console.error("[ClipPlayerController] Failed to load video:", error);
            });
        } else if (playerType === "loading" && clipInfo.is_loading) {
            // Show loading state for clips being generated
            console.log(`[ClipPlayerController] Clip ${clipInfo.clip_id} is loading, showing spinner`);
            this.player.showLoading("Generating temp clip...");
        }

        // Store current state for comparison on updates
        this.currentVideoUrl = videoUrl;
        this.currentPlayerType = playerType;
        this.currentClipId = clipInfo.clip_id;

        // No need for manual event listeners - using reactive LiveView pattern
        console.log("[ClipPlayerController] Using reactive LiveView updates (no manual events needed)");
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

        console.log(`[ClipPlayerController] Update data - URL: ${videoUrl}, Type: ${playerType}`);
        console.log(`[ClipPlayerController] Current state - URL: ${this.currentVideoUrl}, Type: ${this.currentPlayerType}`);

        // Parse updated clip information
        let clipInfo = {};
        try {
            if (clipInfoJson) {
                clipInfo = JSON.parse(clipInfoJson);
            }
        } catch (error) {
            console.error("[ClipPlayerController] Failed to parse updated clip info:", error);
        }

        // Check if video URL changed from loading state to ready state (reactive update)
        const wasLoading = this.currentPlayerType === "loading" || !this.currentVideoUrl;
        const nowReady = videoUrl && playerType && playerType !== "loading";
        const urlChanged = videoUrl && videoUrl !== this.currentVideoUrl;
        const typeChanged = playerType && playerType !== this.currentPlayerType;

        if ((wasLoading && nowReady) || urlChanged || typeChanged) {
            console.log(`[ClipPlayerController] 🎬 Video became ready! Switching to: ${videoUrl} (${playerType})`);
            console.log(`[ClipPlayerController] State change: loading=${wasLoading}, ready=${nowReady}, urlChanged=${urlChanged}`);

            this.currentVideoUrl = videoUrl;
            this.currentPlayerType = playerType;

            // Use switchClip for smooth transitions between clips
            this.player.switchClip(videoUrl, playerType, clipInfo).catch(error => {
                console.error("[ClipPlayerController] Failed to switch to new clip:", error);
            });
        } else {
            console.log(`[ClipPlayerController] No significant changes detected`);
        }
    },

    destroyed() {
        console.log("[ClipPlayerController] Destroyed");

        if (this.player) {
            this.player.destroy();
            this.player = null;
        }

        // No manual event listeners to clean up with reactive pattern

        this.currentVideoUrl = null;
        this.currentPlayerType = null;
        this.currentClipId = null;
    },

    // Event handlers removed - using reactive LiveView pattern instead
};