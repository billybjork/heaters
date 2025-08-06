/**
 * Phoenix LiveView Hook for Clip Player
 * 
 * Integrates the ClipPlayer with Phoenix LiveView using reactive patterns.
 * Handles initialization, data updates, and cleanup for clips in different stages:
 * temp clips (on-demand generated) and exported clips (direct files).
 * 
 * ## Reactive Pattern Implementation
 * 
 * This hook implements a clean Phoenix LiveView reactive pattern that eliminates
 * the need for manual push_event/addEventListener patterns:
 * 
 * 1. LiveView stores temp clip state in assigns (separate from clip struct)
 * 2. PubSub messages from background jobs trigger assign updates
 * 3. updated() lifecycle automatically detects URL/state changes
 * 4. Hook smoothly transitions video player to new content
 * 5. No manual refresh or event handling required
 * 
 * ## AbortError Prevention
 * 
 * Prevents JavaScript AbortError by avoiding competing play() calls:
 * - HTML autoplay attribute removed from video element
 * - Clean state transitions with removeAttribute('src') before loading
 * - Let canplaythrough event handler manage autoplay timing
 */

import { ClipPlayer } from "./clip-player";

export const ClipPlayerController = {
    mounted() {
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
            this.player.showLoading("Generating temp clip...");
        }

        // Store current state for comparison on updates
        this.currentVideoUrl = videoUrl;
        this.currentPlayerType = playerType;
        this.currentClipId = clipInfo.clip_id;
    },

    updated() {
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

        // Reactive Pattern: Detect state transitions from LiveView assign updates
        // This replaces manual push_event patterns with automatic detection
        const wasLoading = this.currentPlayerType === "loading" || !this.currentVideoUrl;
        const nowReady = videoUrl && playerType && playerType !== "loading";
        const urlChanged = videoUrl && videoUrl !== this.currentVideoUrl;
        const typeChanged = playerType && playerType !== this.currentPlayerType;

        if ((wasLoading && nowReady) || urlChanged || typeChanged) {
            this.currentVideoUrl = videoUrl;
            this.currentPlayerType = playerType;

            // Use switchClip for smooth transitions between clips
            this.player.switchClip(videoUrl, playerType, clipInfo).catch(error => {
                console.error("[ClipPlayerController] Failed to switch to new clip:", error);
            });
        }
    },

    destroyed() {

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