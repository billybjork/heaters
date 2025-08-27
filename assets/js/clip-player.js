/**
 * ClipPlayer Hook - Optimized video playback with temp clip files
 * 
 * Core responsibilities:
 * - Video loading and playback management with proper cleanup
 * - Temp clip file playback with instant loading
 * - Integration with FrameNavigator for precise frame control
 * - LiveView event handling with reactive updates
 * 
 * Performance optimizations:
 * - Direct file serving for temp clips (2-5MB files vs 28GB streams)
 * - Proper event handler cleanup to prevent stale references
 * - Intelligent loading states for better UX
 * 
 * Complex responsibilities moved to separate modules:
 * - Frame navigation → FrameNavigator
 * - Split calculations → FrameNavigator
 */

import FrameNavigator from './frame-navigator';

export default {
  mounted() {
    // Get video element - hook is attached directly to the video element
    this.video = this.el.tagName === 'VIDEO' ? this.el : this.el.querySelector('video');
    if (!this.video) {
      console.error('[ClipPlayer] No video element found');
      return;
    }

    // Parse clip information
    const clipInfoData = this.el.dataset.clipInfo;
    const clipInfo = clipInfoData ? JSON.parse(clipInfoData) : {};

    // Initialize frame navigator
    this.frameNavigator = new FrameNavigator(this.video, (event, payload) => this.pushEvent(event, payload));
    
    // Store state
    this.clipInfo = clipInfo;
    this.playerType = null;
    this.currentVideoUrl = null;
    
    // Make accessible to ReviewHotkeys
    this.video._clipPlayer = this;
    
    // Set up video event handlers
    this.setupVideoHandlers();
    
    // Load initial video if URL is provided
    const videoUrl = this.el.dataset.videoUrl;
    const playerType = this.el.dataset.playerType || 'ffmpeg_stream';
    
    if (videoUrl) {
      this.loadVideo(videoUrl, playerType, clipInfo);
    }
  },

  destroyed() {
    // Clean up event handlers first to prevent stale references
    this.cleanupEventHandlers();
    
    // Clean up frame navigator
    if (this.frameNavigator) {
      this.frameNavigator.destroy();
      this.frameNavigator = null;
    }
    
    // Clean up video
    try {
      if (this.video && !this.video.paused) {
        this.video.pause();
      }
    } catch (error) {
      // Ignore errors during destruction
    }
    
    // Clean up references
    if (this.video) {
      this.video._clipPlayer = null;
    }
    
    // Reset state
    this.currentVideoUrl = null;
  },

  updated() {
    // Handle video URL changes (reactive updates from LiveView)
    const newVideoUrl = this.el.dataset.videoUrl;
    const newPlayerType = this.el.dataset.playerType || 'ffmpeg_stream';
    const newClipInfoData = this.el.dataset.clipInfo;
    const newClipInfo = newClipInfoData ? JSON.parse(newClipInfoData) : {};
    
    // Check if we need to switch videos
    const needsNewVideo = newVideoUrl !== this.currentVideoUrl ||
                         newPlayerType !== this.playerType ||
                         JSON.stringify(newClipInfo) !== JSON.stringify(this.clipInfo);
    
    if (needsNewVideo && newVideoUrl) {
      this.switchClip(newVideoUrl, newPlayerType, newClipInfo);
    }
  },

  /**
   * Clean up existing event handlers to prevent stale references
   * CRITICAL: Prevents previous clips' event handlers from interfering with new clips
   */
  cleanupEventHandlers() {
    if (this.eventHandlers && this.video) {
      Object.entries(this.eventHandlers).forEach(([event, handler]) => {
        this.video.removeEventListener(event, handler);
      });
    }
    this.eventHandlers = null;
    
    // Clean up click handler
    if (this.clickHandler && this.video) {
      this.video.removeEventListener('click', this.clickHandler);
    }
    this.clickHandler = null;
  },

  /**
   * Set up video event handlers with proper cleanup tracking
   */
  setupVideoHandlers() {
    // Clean up any existing handlers first
    this.cleanupEventHandlers();
    
    // Store event handler references for cleanup
    this.eventHandlers = {
      loadstart: () => {
        if (this.playerType === 'ffmpeg_stream') {
          this.showLoading();
        }
      },

      loadedmetadata: () => {
        // Don't interfere with split mode
        if (this.frameNavigator?.isSplitModeActive()) {
          return;
        }
        
        // For direct_s3 players, reset time to 0 to ensure clip starts at beginning
        if (this.playerType === 'direct_s3' && 
            this.video.currentTime > 0.01 && 
            this.video.dataset.clipOffsetReset !== '1') {
          this.video.currentTime = 0;
          this.video.dataset.clipOffsetReset = '1';
        }
      },

      canplaythrough: () => {
        // Don't auto-play in split mode
        if (this.frameNavigator?.isSplitModeActive()) {
          return;
        }
        
        this.hideLoading();
        this.attemptAutoplay();
      },

      waiting: () => {
        if (this.playerType === 'ffmpeg_stream') {
          this.showLoading();
        }
      },

      error: (e) => {
        console.error('[ClipPlayer] Video error:', e);
        this.hideLoading();
      },

      ended: () => {
        // Only loop if NOT in split mode
        if (!this.frameNavigator?.isSplitModeActive()) {
          this.video.currentTime = 0;
          this.video.play().catch(error => {
            console.warn('[ClipPlayer] Loop playback failed:', error.message);
          });
        }
      }
    };

    // Add all event listeners
    Object.entries(this.eventHandlers).forEach(([event, handler]) => {
      this.video.addEventListener(event, handler);
    });
    
    // Add click handler for pause/unpause functionality
    this.clickHandler = (e) => {
      // Prevent default behavior and event propagation
      e.preventDefault();
      e.stopPropagation();
      
      // Toggle play/pause state
      if (this.video.paused) {
        this.video.play().catch(e => {
          console.log('[ClipPlayer] Play failed:', e.message);
        });
      } else {
        this.video.pause();
      }
    };
    
    this.video.addEventListener('click', this.clickHandler);
  },

  /**
   * Load a new video with proper event handler setup
   */
  async loadVideo(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
    if (this.frameNavigator?.isSplitModeActive()) {
      console.warn('[ClipPlayer] Loading video during split mode - frame navigation may be reset');
    }

    // Store current state
    this.currentVideoUrl = videoUrl;
    this.playerType = playerType;
    this.clipInfo = clipInfo || {};
    
    // Update FrameNavigator with new clip info
    this.frameNavigator?.updateClipInfo(this.clipInfo);
    
    // Set up fresh event handlers for new video
    this.setupVideoHandlers();
    
    // Pause current video and clean up
    try {
      this.video.pause();
      this.video.removeAttribute('src');
      this.video.load();
    } catch (_) {}
    
    // Show loading for temp clips being generated
    if (playerType === 'ffmpeg_stream') {
      this.showLoading();
    }

    // Set video source
    this.video.src = videoUrl;
  },

  /**
   * Switch to a new clip with proper cleanup
   */
  async switchClip(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
    // Clean slate: reset all state before loading new clip
    this.video.pause();
    
    // Clean up existing handlers to prevent stale references
    this.cleanupEventHandlers();
    
    await this.loadVideo(videoUrl, playerType, clipInfo);
  },

  /**
   * Show loading spinner
   */
  showLoading() {
    const container = this.video.parentElement;
    const loadingSpinner = container?.querySelector('.clip-player-loading');
    if (loadingSpinner) {
      loadingSpinner.style.display = 'block';
    }
  },

  /**
   * Hide loading spinner
   */
  hideLoading() {
    const container = this.video.parentElement;
    const loadingSpinner = container?.querySelector('.clip-player-loading');
    if (loadingSpinner) {
      loadingSpinner.style.display = 'none';
    }
  },

  /**
   * Attempt autoplay (respects browser policies)
   */
  attemptAutoplay() {
    if (this.video.paused) {
      this.video.play().catch(e => {
        console.log('[ClipPlayer] Autoplay prevented:', e.message);
      });
    }
  },

  /**
   * Public API methods for ReviewHotkeys integration
   */
  
  // Split mode control - called by ReviewHotkeys
  enterSplitMode() {
    this.video.pause();
    
    // Notify frame navigator
    if (this.frameNavigator) {
      this.frameNavigator.enterSplitMode();
    }
  },

  exitSplitMode() {
    // Notify frame navigator
    if (this.frameNavigator) {
      this.frameNavigator.exitSplitMode();
    }
    
    this.attemptAutoplay();
  },

  // Frame navigation - called by ReviewHotkeys
  navigateFrames(direction, frameCount = 1) {
    if (this.frameNavigator) {
      this.frameNavigator.navigateFrames(direction, frameCount);
    } else {
      console.warn('[ClipPlayer] Frame navigation ignored - no frame navigator available');
    }
  },

  /**
   * Public API for accessing frame navigator (used by ReviewHotkeys)
   */
  getFrameNavigator() {
    return this.frameNavigator;
  }
};