/**
 * CloudFront Video Player
 * 
 * Simple HTML5 video player that leverages CloudFront's native byte-range support.
 * 
 * Unlike complex WebCodecs or nginx-mp4 implementations, this uses the standard
 * HTML5 video element which automatically handles byte-range requests through
 * CloudFront for efficient seeking and streaming.
 * 
 * Key benefits:
 * - Native browser support (no custom decoders)
 * - CloudFront handles byte-range requests automatically
 * - Simple, maintainable codebase
 * - Works across all modern browsers
 * - Leverages existing proxy file infrastructure
 */

class CloudFrontVideoPlayer {
  constructor(videoElement, options = {}) {
    this.video = videoElement;
    this.options = {
      preload: 'none',
      controls: true,
      ...options
    };
    
    this.isVirtualClip = false;
    this.clipStartTime = 0;
    this.clipEndTime = 0;
    
    this.init();
  }

  init() {
    // Set basic video attributes
    this.video.preload = 'none';
    this.video.controls = this.options.controls;
    
    // Track if video has been loaded
    this.videoLoaded = false;
    this.pendingVideoUrl = null;
    this.pendingClipInfo = null;
    
    // Add event listeners for virtual clip handling
    this.video.addEventListener('loadedmetadata', this.handleLoadedMetadata.bind(this));
    this.video.addEventListener('timeupdate', this.handleTimeUpdate.bind(this));
    this.video.addEventListener('seeking', this.handleSeeking.bind(this));
    
    // Add click listener to load video on first interaction
    this.video.addEventListener('click', this.handleFirstClick.bind(this));
    this.video.addEventListener('play', this.handlePlay.bind(this));
    
    console.log('[CloudFrontVideoPlayer] Initialized');
  }

  /**
   * Update clip information without reloading the video
   * @param {Object} clipInfo - Clip timing information for virtual clips
   */
  updateClipInfo(clipInfo) {
    if (clipInfo && clipInfo.is_virtual) {
      this.isVirtualClip = true;
      this.clipStartTime = clipInfo.start_time_seconds;
      this.clipEndTime = clipInfo.end_time_seconds;
      
      console.log(`[CloudFrontVideoPlayer] Updated clip timing: ${this.clipStartTime}s - ${this.clipEndTime}s`);
      
      // If video is already loaded, seek to new start time
      if (this.video.readyState >= 1) { // HAVE_METADATA
        this.video.currentTime = this.clipStartTime;
      }
    }
  }

  /**
   * Prepare video URL and clip info for lazy loading
   * @param {string} videoUrl - CloudFront URL for the video
   * @param {Object} clipInfo - Optional clip timing information for virtual clips
   */
  async loadVideo(videoUrl, clipInfo = null) {
    console.log(`[CloudFrontVideoPlayer] Preparing video: ${videoUrl}`);
    
    // Store video URL and clip info for lazy loading
    this.pendingVideoUrl = videoUrl;
    this.pendingClipInfo = clipInfo;
    
    // Store virtual clip information
    if (clipInfo && clipInfo.start_time_seconds !== undefined && clipInfo.end_time_seconds !== undefined) {
      this.isVirtualClip = true;
      this.clipStartTime = clipInfo.start_time_seconds;
      this.clipEndTime = clipInfo.end_time_seconds;
      console.log(`[CloudFrontVideoPlayer] Virtual clip prepared: ${this.clipStartTime}s - ${this.clipEndTime}s`);
    } else {
      this.isVirtualClip = false;
      this.clipStartTime = 0;
      this.clipEndTime = 0;
    }

    // Don't actually load the video until user interaction
    console.log('[CloudFrontVideoPlayer] Video prepared for lazy loading');
  }

  /**
   * Actually load the video when user interacts
   */
  async actuallyLoadVideo() {
    if (!this.pendingVideoUrl || this.videoLoaded) {
      return;
    }

    console.log(`[CloudFrontVideoPlayer] Actually loading: ${this.pendingVideoUrl}`);
    
    // Set the source and load metadata only
    this.video.src = this.pendingVideoUrl;
    this.video.preload = 'metadata';
    this.video.load();
    this.videoLoaded = true;
    
    return new Promise((resolve, reject) => {
      const handleCanPlay = () => {
        this.video.removeEventListener('canplay', handleCanPlay);
        this.video.removeEventListener('error', handleError);
        
        // For virtual clips, seek to start time
        if (this.isVirtualClip) {
          this.video.currentTime = this.clipStartTime;
        }
        
        resolve();
      };
      
      const handleError = (event) => {
        this.video.removeEventListener('canplay', handleCanPlay);
        this.video.removeEventListener('error', handleError);
        reject(new Error(`Video load failed: ${event.message || 'Unknown error'}`));
      };
      
      this.video.addEventListener('canplay', handleCanPlay);
      this.video.addEventListener('error', handleError);
    });
  }

  /**
   * Handle loaded metadata - set up virtual clip boundaries
   */
  handleLoadedMetadata() {
    if (this.isVirtualClip) {
      console.log(`[CloudFrontVideoPlayer] Metadata loaded for virtual clip: ${this.clipStartTime}s - ${this.clipEndTime}s`);
      // Start playback at clip start time
      this.video.currentTime = this.clipStartTime;
    }
  }

  /**
   * Handle time updates - enforce virtual clip boundaries
   */
  handleTimeUpdate() {
    if (this.isVirtualClip && this.video.currentTime >= this.clipEndTime) {
      // Reached end of virtual clip, pause and reset to start
      this.video.pause();
      this.video.currentTime = this.clipStartTime;
      
      // Dispatch custom event for clip end
      this.video.dispatchEvent(new CustomEvent('clipended', {
        detail: {
          startTime: this.clipStartTime,
          endTime: this.clipEndTime,
          duration: this.clipEndTime - this.clipStartTime
        }
      }));
    }
  }

  /**
   * Handle seeking - constrain to virtual clip boundaries
   */
  handleSeeking() {
    if (this.isVirtualClip) {
      if (this.video.currentTime < this.clipStartTime) {
        this.video.currentTime = this.clipStartTime;
      } else if (this.video.currentTime > this.clipEndTime) {
        this.video.currentTime = this.clipEndTime;
      }
    }
  }

  /**
   * Handle first click - load video if not already loaded
   */
  async handleFirstClick(event) {
    if (!this.videoLoaded && this.pendingVideoUrl) {
      console.log('[CloudFrontVideoPlayer] First click - loading video');
      await this.actuallyLoadVideo();
    }
  }

  /**
   * Handle play event - load video if not already loaded
   */
  async handlePlay(event) {
    if (!this.videoLoaded && this.pendingVideoUrl) {
      console.log('[CloudFrontVideoPlayer] Play requested - loading video');
      // Pause immediately to prevent error
      this.video.pause();
      await this.actuallyLoadVideo();
      // Resume play after loading
      this.video.play();
    }
  }

  /**
   * Play the video
   */
  async play() {
    try {
      await this.video.play();
    } catch (error) {
      console.error('[CloudFrontVideoPlayer] Play error:', error);
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
   * Seek to a specific time (constrained to clip boundaries if virtual)
   */
  seekTo(timeSeconds) {
    if (this.isVirtualClip) {
      // Constrain to clip boundaries
      const constrainedTime = Math.max(
        this.clipStartTime,
        Math.min(this.clipEndTime, timeSeconds)
      );
      this.video.currentTime = constrainedTime;
    } else {
      this.video.currentTime = timeSeconds;
    }
  }

  /**
   * Get current playback time (relative to clip start for virtual clips)
   */
  getCurrentTime() {
    if (this.isVirtualClip) {
      return Math.max(0, this.video.currentTime - this.clipStartTime);
    }
    return this.video.currentTime;
  }

  /**
   * Get clip duration
   */
  getDuration() {
    if (this.isVirtualClip) {
      return this.clipEndTime - this.clipStartTime;
    }
    return this.video.duration || 0;
  }

  /**
   * Destroy the player and clean up event listeners
   */
  destroy() {
    this.video.removeEventListener('loadedmetadata', this.handleLoadedMetadata);
    this.video.removeEventListener('timeupdate', this.handleTimeUpdate);
    this.video.removeEventListener('seeking', this.handleSeeking);
    this.video.removeEventListener('click', this.handleFirstClick);
    this.video.removeEventListener('play', this.handlePlay);
    
    this.video.src = '';
    this.video.load();
    
    console.log('[CloudFrontVideoPlayer] Destroyed');
  }
}

export { CloudFrontVideoPlayer };