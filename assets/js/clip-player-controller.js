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

        // Set up event listeners for LiveView push events
        this.handleEvent("temp_clip_ready", (data) => this.onTempClipReady(data));
        this.handleEvent("temp_clip_error", (data) => this.onTempClipError(data));
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
        this.currentClipId = null;
    },

    // Handle temp clip ready events from LiveView
    onTempClipReady(data) {
        console.log(`[ClipPlayerController] Received temp_clip_ready for clip ${data.clip_id}`);
        
        // Check if this is for the current clip
        if (this.currentClipId && data.clip_id.toString() === this.currentClipId.toString()) {
            console.log(`[ClipPlayerController] Loading generated clip for current clip ${data.clip_id}`);
            
            if (this.player) {
                // Load the newly generated clip
                this.player.loadVideo(data.path, "direct_s3", { clip_id: data.clip_id })
                    .catch(error => {
                        console.error(`[ClipPlayerController] Failed to load generated clip: ${error}`);
                    });
                
                // Update tracking state
                this.currentVideoUrl = data.path;
                this.currentPlayerType = "direct_s3";
            }
        } else {
            console.log(`[ClipPlayerController] Ignoring temp_clip_ready for clip ${data.clip_id} (current: ${this.currentClipId})`);
        }
    },

    onTempClipError(data) {
        console.error(`[ClipPlayerController] Received temp_clip_error for clip ${data.clip_id}: ${data.error}`);
        
        // Check if this is for the current clip
        if (this.currentClipId && data.clip_id.toString() === this.currentClipId.toString()) {
            if (this.player) {
                this.player.hideLoading();
                // Could show an error state here
            }
        }
    }
};