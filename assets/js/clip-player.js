/**
 * Clip Player
 * 
 * HTML5 video player for clips in different lifecycle stages.
 * 
 * This player handles two types of video sources:
 * 1. Temp clips: Small MP4 files (2-5MB) generated on-demand using FFmpeg stream copy
 * 2. Exported clips: Direct file URLs for finalized clips
 * 
 * Key benefits:
 * - Temp clips use tiny files with instant playback and correct timeline duration
 * - Each clip feels like a standalone file with proper timeline (no byte-range confusion)
 * - No complex streaming protocols - just simple file serving
 * - Simple, maintainable codebase with native HTML5 video
 * - Foundation for sequential clip playback
 */

class ClipPlayer {
    constructor(videoElement, options = {}) {
        this.video = videoElement;
        this.options = {
            preload: 'metadata',
            controls: true,
            showLoadingSpinner: true,
            ...options
        };

        this.playerType = null; // 'ffmpeg_stream' or 'direct_s3'
        this.isLoading = false;
        this.isLoadingNewVideo = false;
        this.loadingSpinner = null;

        this.init();
    }

    init() {
        // Don't override template attributes - they're set correctly
        // this.video.preload = this.options.preload;
        // this.video.controls = this.options.controls;

        // Add loading state management
        this.setupLoadingSpinner();

        // Add event listeners for clip playback behavior
        this.video.addEventListener('loadstart', this.handleLoadStart.bind(this));
        this.video.addEventListener('loadedmetadata', this.handleLoadedMetadata.bind(this));
        this.video.addEventListener('canplay', this.handleCanPlay.bind(this));
        this.video.addEventListener('canplaythrough', this.handleCanPlayThrough.bind(this));
        this.video.addEventListener('waiting', this.handleWaiting.bind(this));
        this.video.addEventListener('error', this.handleError.bind(this));

        // Add custom clip ended event for looping
        this.video.addEventListener('ended', this.handleEnded.bind(this));

        console.log('[ClipPlayer] Initialized');
    }

    setupLoadingSpinner() {
        if (!this.options.showLoadingSpinner) return;

        // Find existing loading spinner in the template
        const container = this.video.parentElement;
        this.loadingSpinner = container?.querySelector('.clip-player-loading');

        if (!this.loadingSpinner) {
            console.warn('[ClipPlayer] Loading spinner not found in template');
        }
    }

    /**
     * Load a video clip for playback
     * @param {string} videoUrl - Video URL (on-demand generated or direct file)
     * @param {string} playerType - 'ffmpeg_stream' or 'direct_s3' 
     * @param {Object} clipInfo - Clip metadata (mainly for logging/debugging)
     */
    async loadVideo(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
        if (!videoUrl) {
            console.error('[ClipPlayer] No video URL provided');
            return;
        }

        console.log(`[ClipPlayer] Loading ${playerType} video: ${videoUrl}`);

        // Clean handshake to prevent AbortError
        try {
            await this.video.pause();
        } catch (_) { }

        this.video.src = '';
        this.video.load();

        this.playerType = playerType;
        this.clipInfo = clipInfo;  // Store clip info for later use

        // Show loading spinner for FFmpeg streams (they have startup latency)
        if (playerType === 'ffmpeg_stream') {
            this.showLoading('Loading clip...');
        }

        // Set new clip
        this.video.src = videoUrl;

        // Swallow AbortError safely
        this.video.play().catch(() => { });

        // Log clip info for debugging
        if (clipInfo) {
            console.log(`[ClipPlayer] Clip info:`, clipInfo);
        }
    }

    /**
     * Switch to a new clip (for sequential playback)
     * @param {string} videoUrl - New video URL
     * @param {string} playerType - Player type
     * @param {Object} clipInfo - New clip metadata  
     */
    async switchClip(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
        console.log(`[ClipPlayer] Switching to new clip: ${videoUrl}`);

        // Pause current playback
        this.video.pause();

        // Load new clip
        await this.loadVideo(videoUrl, playerType, clipInfo);

        // Auto-play new clip (browser permitting)
        try {
            await this.video.play();
        } catch (error) {
            console.log('[ClipPlayer] Auto-play prevented, waiting for user interaction');
        }
    }

    /**
     * Handle load start - show loading spinner
     */
    handleLoadStart() {
        console.log('[ClipPlayer] Load started');
        if (this.playerType === 'ffmpeg_stream') {
            this.showLoading('Loading clip...');
        }
    }

    /**
     * Handle metadata loaded - clip is ready to play
     */
    handleLoadedMetadata() {
        console.log('[ClipPlayer] Metadata loaded - clip ready');

        // Reset timeline for tiny-file URLs to ensure clean playback
        if (this.playerType === 'direct_s3' && this.video.currentTime > 0.01 &&
            this.video.dataset.clipOffsetReset !== '1') {
            this.video.currentTime = 0;
            this.video.dataset.clipOffsetReset = '1';
        }
    }

    /**
     * Handle can play - video is ready for playback
     */
    handleCanPlay() {
        console.log('[ClipPlayer] Can play - video is ready but may still buffer');
        // Don't autoplay yet - wait for canplaythrough for better experience
    }

    /**
     * Handle can play through - video can play without buffering interruptions
     */
    handleCanPlayThrough() {
        console.log('[ClipPlayer] Can play through - hiding loading spinner and starting autoplay');
        this.hideLoading();

        // Try autoplay immediately
        this.attemptAutoplay();
    }

    /**
     * Attempt autoplay with multiple strategies
     */
    async attemptAutoplay() {
        try {
            console.log('[ClipPlayer] Attempting autoplay...');
            await this.video.play();
            console.log('[ClipPlayer] Autoplay succeeded');
        } catch (error) {
            console.log('[ClipPlayer] Autoplay failed:', error);

            // Try one more time after a brief delay
            setTimeout(async () => {
                try {
                    console.log('[ClipPlayer] Retrying autoplay after delay...');
                    await this.video.play();
                    console.log('[ClipPlayer] Delayed autoplay succeeded');
                } catch (retryError) {
                    console.log('[ClipPlayer] Autoplay blocked by browser policy - user must click play');
                }
            }, 100);
        }
    }

    /**
     * Handle waiting - show loading spinner during buffering
     */
    handleWaiting() {
        console.log('[ClipPlayer] Waiting for data');
        if (this.playerType === 'ffmpeg_stream') {
            this.showLoading('Buffering...');
        }
    }

    /**
     * Handle video errors
     */
    handleError(event) {
        // Ignore empty src errors during video transitions
        if (this.video.error && this.video.error.code === 4 &&
            (this.video.error.message.includes('Empty src attribute') ||
                this.video.error.message.includes('MEDIA_ELEMENT_ERROR: Empty src attribute'))) {
            console.log('[ClipPlayer] Ignoring empty src error during video transition');
            return;
        }

        // Ignore errors during new video loading
        if (this.isLoadingNewVideo) {
            console.log('[ClipPlayer] Ignoring error during new video load');
            return;
        }

        console.error('[ClipPlayer] Video error:', event);
        console.error('[ClipPlayer] Video error details:', {
            error: this.video.error,
            networkState: this.video.networkState,
            readyState: this.video.readyState,
            currentSrc: this.video.currentSrc
        });

        if (this.video.error) {
            console.error('[ClipPlayer] MediaError code:', this.video.error.code);
            console.error('[ClipPlayer] MediaError message:', this.video.error.message);
        }

        this.hideLoading();

        // Dispatch custom error event
        this.video.dispatchEvent(new CustomEvent('cliperror', {
            detail: {
                error: event,
                playerType: this.playerType
            }
        }));
    }

    /**
     * Handle video end - for clips, just pause; for full videos, loop back to beginning
     */
    handleEnded() {
        console.log('[ClipPlayer] Clip ended');

        // Check if this is a clip (based on player type or clip info)
        const isClip = this.playerType === 'direct_s3' || this.clipInfo;

        if (isClip) {
            console.log('[ClipPlayer] Clip finished playing - stopping');
            // For clips, just stay at the end (don't loop)
        } else {
            console.log('[ClipPlayer] Video ended - looping back to start');
            // Reset to beginning and continue playing for full videos
            this.video.currentTime = 0;
            this.video.play().catch(error => {
                console.log('[ClipPlayer] Loop playback failed:', error);
            });
        }

        // Dispatch custom event for clip end (useful for sequential playback)
        this.video.dispatchEvent(new CustomEvent('clipended', {
            detail: {
                playerType: this.playerType,
                currentTime: this.video.currentTime,
                duration: this.video.duration,
                looped: true
            }
        }));
    }

    /**
     * Show loading spinner with custom message
     */
    showLoading(message = 'Loading...') {
        if (!this.loadingSpinner) return;

        this.isLoading = true;
        this.loadingSpinner.querySelector('.loading-text').textContent = message;
        this.loadingSpinner.style.display = 'block';
    }

    /**
     * Hide loading spinner
     */
    hideLoading() {
        if (!this.loadingSpinner) return;

        this.isLoading = false;
        this.loadingSpinner.style.display = 'none';
    }

    /**
     * Play the video
     */
    async play() {
        try {
            await this.video.play();
        } catch (error) {
            console.error('[ClipPlayer] Play error:', error);
            throw error;
        }
    }

    /**
     * Pause the video
     */
    pause() {
        this.video.pause();
    }

    /**
     * Seek to a specific time (0-based timeline for each clip)
     */
    seekTo(timeSeconds) {
        // No constraints needed - each clip is treated as a standalone file
        this.video.currentTime = Math.max(0, Math.min(this.video.duration || 0, timeSeconds));
    }

    /**
     * Get current playback time (0-based for each clip)
     */
    getCurrentTime() {
        return this.video.currentTime;
    }

    /**
     * Get clip duration (native duration of clip)
     */
    getDuration() {
        return this.video.duration || 0;
    }

    /**
     * Loop the current clip
     */
    loop() {
        this.video.loop = true;
    }

    /**
     * Disable looping
     */
    unloop() {
        this.video.loop = false;
    }

    /**
     * Check if player is currently loading
     */
    isLoadingState() {
        return this.isLoading;
    }

    /**
     * Get the current player type
     */
    getPlayerType() {
        return this.playerType;
    }

    /**
     * Destroy the player and clean up event listeners
     */
    destroy() {
        console.log('[ClipPlayer] Destroying player...');

        // Stop playback gracefully before cleanup
        try {
            if (!this.video.paused) {
                this.video.pause();
            }
        } catch (error) {
            // Ignore errors during destruction
        }

        // Remove event listeners
        this.video.removeEventListener('loadstart', this.handleLoadStart);
        this.video.removeEventListener('loadedmetadata', this.handleLoadedMetadata);
        this.video.removeEventListener('canplay', this.handleCanPlay);
        this.video.removeEventListener('canplaythrough', this.handleCanPlayThrough);
        this.video.removeEventListener('waiting', this.handleWaiting);
        this.video.removeEventListener('error', this.handleError);
        this.video.removeEventListener('ended', this.handleEnded);

        // Hide loading spinner (don't remove as it's part of the template)
        if (this.loadingSpinner) {
            this.hideLoading();
            this.loadingSpinner = null;
        }

        // Clear state flags
        this.isLoadingNewVideo = false;
        this.isLoading = false;

        // Clear video source
        this.video.src = '';
        this.video.load();

        console.log('[ClipPlayer] Destroyed');
    }
}

export { ClipPlayer };