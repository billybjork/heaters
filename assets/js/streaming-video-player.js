/**
 * Streaming Video Player
 * 
 * HTML5 video player for server-side FFmpeg streaming.
 * 
 * This player handles two types of video sources:
 * 1. Virtual clips: Streamed via FFmpeg time segmentation (feels like standalone files)
 * 2. Physical clips: Direct file URLs for exported clips
 * 
 * Key benefits:
 * - Virtual clips stream only exact time ranges (no full video downloads)
 * - Each clip feels like a standalone file with 0-based timeline
 * - Automatic loading indicators for FFmpeg startup latency
 * - Simple, maintainable codebase with native HTML5 video
 * - Foundation for sequential clip playback
 */

class StreamingVideoPlayer {
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
    this.loadingSpinner = null;
    
    this.init();
  }

  init() {
    // Set basic video attributes
    this.video.preload = this.options.preload;
    this.video.controls = this.options.controls;
    
    // Add loading state management
    this.setupLoadingSpinner();
    
    // Add event listeners for streaming behavior
    this.video.addEventListener('loadstart', this.handleLoadStart.bind(this));
    this.video.addEventListener('loadedmetadata', this.handleLoadedMetadata.bind(this));
    this.video.addEventListener('canplay', this.handleCanPlay.bind(this));
    this.video.addEventListener('waiting', this.handleWaiting.bind(this));
    this.video.addEventListener('error', this.handleError.bind(this));
    
    // Add custom clip ended event for looping
    this.video.addEventListener('ended', this.handleEnded.bind(this));
    
    console.log('[StreamingVideoPlayer] Initialized');
  }

  setupLoadingSpinner() {
    if (!this.options.showLoadingSpinner) return;
    
    // Create loading spinner element
    this.loadingSpinner = document.createElement('div');
    this.loadingSpinner.className = 'streaming-video-loading';
    this.loadingSpinner.innerHTML = `
      <div class="spinner"></div>
      <div class="loading-text">Loading clip...</div>
    `;
    this.loadingSpinner.style.cssText = `
      position: absolute;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      z-index: 10;
      display: none;
      text-align: center;
      color: white;
      background: rgba(0,0,0,0.7);
      padding: 20px;
      border-radius: 8px;
    `;
    
    // Add spinner styles
    const spinnerCSS = `
      .streaming-video-loading .spinner {
        border: 3px solid rgba(255,255,255,0.3);
        border-top: 3px solid white;
        border-radius: 50%;
        width: 30px;
        height: 30px;
        animation: spin 1s linear infinite;
        margin: 0 auto 10px;
      }
      @keyframes spin {
        0% { transform: rotate(0deg); }
        100% { transform: rotate(360deg); }
      }
    `;
    
    // Add CSS if not already added
    if (!document.querySelector('#streaming-video-spinner-css')) {
      const style = document.createElement('style');
      style.id = 'streaming-video-spinner-css';
      style.textContent = spinnerCSS;
      document.head.appendChild(style);
    }
    
    // Insert spinner relative to video
    const container = this.video.parentElement;
    if (container && getComputedStyle(container).position === 'static') {
      container.style.position = 'relative';
    }
    this.video.parentElement?.appendChild(this.loadingSpinner);
  }

  /**
   * Load a video clip for streaming
   * @param {string} videoUrl - Streaming URL or direct file URL
   * @param {string} playerType - 'ffmpeg_stream' or 'direct_s3' 
   * @param {Object} clipInfo - Clip metadata (mainly for logging/debugging)
   */
  async loadVideo(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
    if (!videoUrl) {
      console.error('[StreamingVideoPlayer] No video URL provided');
      return;
    }

    console.log(`[StreamingVideoPlayer] Loading ${playerType} video: ${videoUrl}`);
    
    this.playerType = playerType;
    
    // Show loading spinner for FFmpeg streams (they have startup latency)
    if (playerType === 'ffmpeg_stream') {
      this.showLoading('Streaming clip...');
    }
    
    // Set the source - browser handles the rest
    this.video.src = videoUrl;
    this.video.load();
    
    // Log clip info for debugging
    if (clipInfo) {
      console.log(`[StreamingVideoPlayer] Clip info:`, clipInfo);
    }
  }

  /**
   * Switch to a new clip (for sequential playback)
   * @param {string} videoUrl - New streaming URL
   * @param {string} playerType - Player type
   * @param {Object} clipInfo - New clip metadata  
   */
  async switchClip(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
    console.log(`[StreamingVideoPlayer] Switching to new clip: ${videoUrl}`);
    
    // Pause current playback
    this.video.pause();
    
    // Load new clip
    await this.loadVideo(videoUrl, playerType, clipInfo);
    
    // Auto-play new clip (browser permitting)
    try {
      await this.video.play();
    } catch (error) {
      console.log('[StreamingVideoPlayer] Auto-play prevented, waiting for user interaction');
    }
  }

  /**
   * Handle load start - show loading spinner
   */
  handleLoadStart() {
    console.log('[StreamingVideoPlayer] Load started');
    if (this.playerType === 'ffmpeg_stream') {
      this.showLoading('Streaming clip...');
    }
  }

  /**
   * Handle metadata loaded - clip is ready to play
   */
  handleLoadedMetadata() {
    console.log('[StreamingVideoPlayer] Metadata loaded - clip ready');
    // Metadata loaded, but might still be buffering
  }

  /**
   * Handle can play - video is ready for playback
   */
  handleCanPlay() {
    console.log('[StreamingVideoPlayer] Can play - hiding loading spinner');
    this.hideLoading();
  }

  /**
   * Handle waiting - show loading spinner during buffering
   */
  handleWaiting() {
    console.log('[StreamingVideoPlayer] Waiting for data');
    if (this.playerType === 'ffmpeg_stream') {
      this.showLoading('Buffering...');
    }
  }

  /**
   * Handle video errors
   */
  handleError(event) {
    console.error('[StreamingVideoPlayer] Video error:', event);
    this.hideLoading();
    
    // Dispatch custom error event
    this.video.dispatchEvent(new CustomEvent('streamingerror', {
      detail: {
        error: event,
        playerType: this.playerType
      }
    }));
  }

  /**
   * Handle video end - dispatch clip ended event for looping/sequential playback
   */
  handleEnded() {
    console.log('[StreamingVideoPlayer] Clip ended');
    
    // Dispatch custom event for clip end (useful for sequential playback)
    this.video.dispatchEvent(new CustomEvent('clipended', {
      detail: {
        playerType: this.playerType,
        currentTime: this.video.currentTime,
        duration: this.video.duration
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
      console.error('[StreamingVideoPlayer] Play error:', error);
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
   * Get clip duration (native duration of streamed clip)
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
    // Remove event listeners
    this.video.removeEventListener('loadstart', this.handleLoadStart);
    this.video.removeEventListener('loadedmetadata', this.handleLoadedMetadata);
    this.video.removeEventListener('canplay', this.handleCanPlay);
    this.video.removeEventListener('waiting', this.handleWaiting);
    this.video.removeEventListener('error', this.handleError);
    this.video.removeEventListener('ended', this.handleEnded);
    
    // Clean up loading spinner
    if (this.loadingSpinner) {
      this.loadingSpinner.remove();
      this.loadingSpinner = null;
    }
    
    // Clear video source
    this.video.src = '';
    this.video.load();
    
    console.log('[StreamingVideoPlayer] Destroyed');
  }
}

export { StreamingVideoPlayer };