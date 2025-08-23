// ClipPlayer Hook - Regular JavaScript Hook for Video Playback
export default {
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
      console.error("[ClipPlayer] Failed to parse clip info:", error);
    }

    // Create the player instance
    this.player = new ClipPlayerCore(videoElement, {
      controls: true,
      preload: 'metadata',
      showLoadingSpinner: true
    });

    // Make player accessible to ReviewHotkeys via the video element
    videoElement._clipPlayer = this.player;

    // Load the video if URL is provided
    if (videoUrl) {
      this.player.loadVideo(videoUrl, playerType, clipInfo).catch(error => {
        console.error("[ClipPlayer] Failed to load video:", error);
      });
    }

    // Store current state for updates
    this.currentVideoUrl = videoUrl;
    this.currentPlayerType = playerType;
    this.currentClipId = clipInfo.clip_id;

    console.log("[ClipPlayer] Player accessible at video._clipPlayer");
  },

  updated() {
    if (!this.player) return;

    const videoElement = this.el;
    const videoUrl = videoElement.dataset.videoUrl;
    const playerType = videoElement.dataset.playerType;
    const clipInfoJson = videoElement.dataset.clipInfo;

    let clipInfo = {};
    try {
      if (clipInfoJson) {
        clipInfo = JSON.parse(clipInfoJson);
      }
    } catch (error) {
      console.error("[ClipPlayer] Failed to parse updated clip info:", error);
    }

    // Check for state changes
    const urlChanged = videoUrl && videoUrl !== this.currentVideoUrl;
    const typeChanged = playerType && playerType !== this.currentPlayerType;

    if (urlChanged || typeChanged) {
      this.currentVideoUrl = videoUrl;
      this.currentPlayerType = playerType;
      this.player.switchClip(videoUrl, playerType, clipInfo).catch(error => {
        console.error("[ClipPlayer] Failed to switch to new clip:", error);
      });
    }
  },

  destroyed() {
    if (this.player) {
      this.player.destroy();
      this.player = null;
    }
  }
}

// ClipPlayer Core - Simple video player
class ClipPlayerCore {
  constructor(videoElement, options = {}) {
    this.video = videoElement;
    this.options = {
      preload: 'metadata',
      controls: true,
      showLoadingSpinner: true,
      ...options
    };

    this.playerType = null;
    this.isLoading = false;
    this.loadingSpinner = null;
    this.splitModeActive = false; // Track split mode

    this.init();
  }

  init() {
    this.setupLoadingSpinner();
    this.setupEventHandlers();
    console.log('[ClipPlayer] Initialized');
  }

  setupLoadingSpinner() {
    if (!this.options.showLoadingSpinner) return;
    const container = this.video.parentElement;
    this.loadingSpinner = container?.querySelector('.clip-player-loading');
  }

  setupEventHandlers() {
    // Store bound handlers for cleanup
    this.boundHandlers = {
      loadstart: this.handleLoadStart.bind(this),
      loadedmetadata: this.handleLoadedMetadata.bind(this),
      canplaythrough: this.handleCanPlayThrough.bind(this),
      waiting: this.handleWaiting.bind(this),
      error: this.handleError.bind(this),
      ended: this.handleEnded.bind(this)
    };

    // Add initial event listeners
    this._addEventListeners();
  }

  async loadVideo(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
    if (!videoUrl) {
      console.error('[ClipPlayer] No video URL provided');
      return;
    }

    if (this.splitModeActive) {
      console.log('[ClipPlayer] WARNING: loadVideo called during split mode - this might reset frame navigation');
    }

    console.log(`[ClipPlayer] Loading ${playerType} video: ${videoUrl}`);

    try {
      this.video.pause();
      this.video.removeAttribute('src');
      this.video.load();
    } catch (_) { }

    this.playerType = playerType;
    this.clipInfo = clipInfo;

    if (playerType === 'ffmpeg_stream') {
      this.showLoading();
    }

    this.video.src = videoUrl;
  }

  async switchClip(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
    console.log(`[ClipPlayer] Switching to new clip: ${videoUrl}`);
    this.video.pause();
    
    if (playerType === 'ffmpeg_stream') {
      this.showLoading();
    }
    
    await this.loadVideo(videoUrl, playerType, clipInfo);
  }

  handleLoadStart() {
    console.log('[ClipPlayer] Load started');
    if (this.playerType === 'ffmpeg_stream') {
      this.showLoading();
    }
  }

  handleLoadedMetadata() {
    console.log('[ClipPlayer] Metadata loaded');
    
    // In split mode, do nothing to avoid interfering with frame navigation
    if (this.splitModeActive) {
      console.log('[ClipPlayer] Ignoring loadedmetadata - in split mode');
      return;
    }
    
    // Only reset time for direct_s3 players
    if (this.playerType === 'direct_s3' && 
        this.video.currentTime > 0.01 && this.video.dataset.clipOffsetReset !== '1') {
      console.log('[ClipPlayer] Resetting video time to 0 for direct_s3 player');
      this.video.currentTime = 0;
      this.video.dataset.clipOffsetReset = '1';
    }
  }

  handleCanPlayThrough() {
    console.log('[ClipPlayer] Can play through');
    
    // In split mode, do absolutely nothing to avoid interfering with frame navigation
    if (this.splitModeActive) {
      console.log('[ClipPlayer] Ignoring canplaythrough - in split mode');
      return;
    }
    
    this.hideLoading();
    this.attemptAutoplay();
  }

  async attemptAutoplay() {
    try {
      console.log('[ClipPlayer] Attempting autoplay...');
      await this.video.play();
      console.log('[ClipPlayer] Autoplay succeeded');
    } catch (error) {
      console.log('[ClipPlayer] Autoplay failed:', error);
    }
  }

  handleWaiting() {
    console.log('[ClipPlayer] Waiting for data');
    if (this.playerType === 'ffmpeg_stream') {
      this.showLoading();
    }
  }

  handleError(event) {
    console.error('[ClipPlayer] Video error:', event);
    this.hideLoading();
  }

  handleEnded() {
    console.log('[ClipPlayer] Clip ended');
    
    // Only loop if NOT in split mode
    if (!this.splitModeActive) {
      console.log('[ClipPlayer] Looping back to start');
      this.video.currentTime = 0;
      this.video.play().catch(error => {
        console.log('[ClipPlayer] Loop playback failed:', error);
      });
    }
  }

  // Split mode control - called by ReviewHotkeys
  enterSplitMode() {
    console.log('[ClipPlayer] Entering split mode - disabling automatic behaviors');
    this.splitModeActive = true;
    this.video.pause();
    
    // Temporarily remove all event listeners that might interfere
    this._removeEventListeners();
  }

  exitSplitMode() {
    console.log('[ClipPlayer] Exiting split mode - enabling automatic behaviors');
    this.splitModeActive = false;
    
    // Restore event listeners
    this._addEventListeners();
    
    this.attemptAutoplay();
  }

  // Remove all event listeners during split mode
  _removeEventListeners() {
    if (this.boundHandlers) {
      this.video.removeEventListener('loadstart', this.boundHandlers.loadstart);
      this.video.removeEventListener('loadedmetadata', this.boundHandlers.loadedmetadata);
      this.video.removeEventListener('canplaythrough', this.boundHandlers.canplaythrough);
      this.video.removeEventListener('waiting', this.boundHandlers.waiting);
      this.video.removeEventListener('error', this.boundHandlers.error);
      this.video.removeEventListener('ended', this.boundHandlers.ended);
      console.log('[ClipPlayer] All event listeners removed for split mode');
    }
  }

  // Restore all event listeners after split mode
  _addEventListeners() {
    if (this.boundHandlers) {
      this.video.addEventListener('loadstart', this.boundHandlers.loadstart);
      this.video.addEventListener('loadedmetadata', this.boundHandlers.loadedmetadata);
      this.video.addEventListener('canplaythrough', this.boundHandlers.canplaythrough);
      this.video.addEventListener('waiting', this.boundHandlers.waiting);
      this.video.addEventListener('error', this.boundHandlers.error);
      this.video.addEventListener('ended', this.boundHandlers.ended);
      console.log('[ClipPlayer] All event listeners restored after split mode');
    }
  }

  // Frame navigation - called by ReviewHotkeys
  // TODO: Implement frame-by-frame navigation for split mode
  navigateFrames(direction, frameCount = 3) {
    if (!this.splitModeActive) {
      console.log('[ClipPlayer] Frame navigation ignored - not in split mode');
      return;
    }
    
    console.log(`[ClipPlayer] Frame navigation ${direction} by ${frameCount} frames - TODO: implement proper seeking`);
    
    // Placeholder: Currently just pauses the video
    // Future implementation will handle frame-accurate navigation
  }

  showLoading() {
    if (!this.loadingSpinner) return;
    this.isLoading = true;
    this.loadingSpinner.style.display = 'block';
  }

  hideLoading() {
    if (!this.loadingSpinner) return;
    this.isLoading = false;
    this.loadingSpinner.style.display = 'none';
  }

  destroy() {
    console.log('[ClipPlayer] Destroying...');

    try {
      if (!this.video.paused) {
        this.video.pause();
      }
    } catch (error) {
      // Ignore errors during destruction
    }

    // Remove event listeners
    if (this.boundHandlers) {
      this.video.removeEventListener('loadstart', this.boundHandlers.loadstart);
      this.video.removeEventListener('loadedmetadata', this.boundHandlers.loadedmetadata);
      this.video.removeEventListener('canplaythrough', this.boundHandlers.canplaythrough);
      this.video.removeEventListener('waiting', this.boundHandlers.waiting);
      this.video.removeEventListener('error', this.boundHandlers.error);
      this.video.removeEventListener('ended', this.boundHandlers.ended);
    }

    if (this.loadingSpinner) {
      this.hideLoading();
      this.loadingSpinner = null;
    }

    this.video.src = '';
    this.video.load();

    console.log('[ClipPlayer] Destroyed');
  }
}