/**
 * Frame Navigator - Frame-accurate navigation for video review
 * 
 * Handles precise frame stepping and split operations for virtual subclips.
 * Uses simplified server-side coordinate calculations to eliminate client-side
 * brittleness while maintaining frame-accurate navigation.
 * 
 * KEY INSIGHT: All complex frame calculations now happen server-side using
 * authoritative database FPS data. Client only sends relative time offsets.
 */

export default class FrameNavigator {
  constructor(video, pushEvent) {
    this.video = video;
    this.pushEvent = pushEvent;
    this.splitModeActive = false;
    this.seekInProgress = false;
    this.clipInfo = null;
    this._seekAttempts = 0;
  }

  /**
   * Enter split mode - enables frame-accurate navigation
   */
  enterSplitMode(clipInfo) {
    console.log('[FrameNavigator] Entering split mode');
    this.splitModeActive = true;
    this.clipInfo = clipInfo;
    this._seekAttempts = 0;
    
    // Stop any ongoing playback for precision
    this.video.pause();
    
    // Notify LiveView of split mode change
    this.pushEvent('split_mode_changed', { active: true });
  }

  /**
   * Exit split mode - returns to normal playback
   */
  exitSplitMode() {
    console.log('[FrameNavigator] Exiting split mode');
    this.splitModeActive = false;
    this.seekInProgress = false;
    this.clipInfo = null;
    this._seekAttempts = 0;
    
    // Notify LiveView of split mode change  
    this.pushEvent('split_mode_changed', { active: false });
  }

  /**
   * Frame Navigation for Virtual Subclips
   * 
   * Implements precise frame stepping using database FPS data for split mode.
   * The video element maintains absolute source video time coordinates, while
   * split calculations are handled server-side for reliability.
   * 
   * SIMPLIFIED APPROACH:
   * - video.currentTime remains absolute source video time
   * - frameTime = 1/fps gives the time delta for one frame  
   * - targetTime = currentTime +/- frameTime (absolute coordinates)
   * - Split operations send relative time offsets to server
   * - Server handles all coordinate translation and frame calculations
   */
  navigateFrames(direction, frameCount = 1) {
    if (!this.splitModeActive) {
      console.log('[FrameNavigator] Frame navigation ignored - not in split mode');
      return;
    }
    
    // Don't start a new seek if one is already in progress
    if (this.seekInProgress) {
      // Only log every 5th attempt to reduce console spam
      this._seekAttempts = (this._seekAttempts || 0) + 1;
      if (this._seekAttempts % 5 === 0) {
        console.log(`[FrameNavigator] Frame navigation ignored - seek already in progress (${this._seekAttempts} attempts)`);
      }
      return;
    }
    
    // Reset attempt counter on successful seek
    this._seekAttempts = 0;
    
    // Check if video is ready for seeking
    if (this.video.readyState < 2) {
      console.log('[FrameNavigator] Frame navigation ignored - video not ready for seeking');
      return;
    }

    // CRITICAL: FPS must come from database - never assume
    const fps = this.clipInfo?.fps;
    if (!fps || fps <= 0) {
      console.error('[FrameNavigator] Missing or invalid FPS data - frame navigation disabled');
      console.error('[FrameNavigator] ClipInfo:', this.clipInfo);
      return;
    }
    
    const frameTime = 1 / fps;
    
    // Calculate target time in absolute source video coordinates
    let targetTime;
    if (direction === 'forward' || direction === 'right') {
      targetTime = this.video.currentTime + (frameTime * frameCount);
    } else if (direction === 'backward' || direction === 'left') {
      targetTime = this.video.currentTime - (frameTime * frameCount);
    }
    
    console.log(`[FrameNavigator] Stepping ${direction}: ${this.video.currentTime.toFixed(3)}s → ${targetTime.toFixed(3)}s (${frameTime.toFixed(4)}s per frame)`);
    
    this.seekToTime(targetTime);
  }

  /**
   * Commit split at current video position using simplified time offset approach
   * 
   * This eliminates the complex coordinate translation by sending the relative
   * time offset to the server, which handles all frame calculations using
   * authoritative database FPS data.
   */
  commitSplit() {
    if (!this.splitModeActive) {
      console.log('[FrameNavigator] Split commit ignored - not in split mode');
      return;
    }

    const currentTime = this.video.currentTime;
    const clipStartTime = this.clipInfo?.start_time_seconds || 0;
    const clipEndTime = this.clipInfo?.end_time_seconds || 0;
    
    // Calculate relative time offset from clip start
    const timeOffsetSeconds = currentTime - clipStartTime;
    const clipDuration = clipEndTime - clipStartTime;
    
    console.log(`[FrameNavigator] Simplified split calculation:
  Video time: ${currentTime.toFixed(3)}s (absolute source time)
  Clip start: ${clipStartTime}s
  Clip end: ${clipEndTime}s  
  Time offset from clip start: ${timeOffsetSeconds.toFixed(3)}s
  Clip duration: ${clipDuration.toFixed(3)}s`);

    // Basic bounds checking (server will do authoritative validation)
    if (timeOffsetSeconds <= 0.01) {
      console.warn('[FrameNavigator] Split too close to clip start, skipping');
      return;
    }

    if (timeOffsetSeconds >= (clipDuration - 0.01)) {
      console.warn('[FrameNavigator] Split too close to clip end, skipping');
      return;
    }

    // Send relative time offset to server for authoritative frame calculation
    this.pushEvent("split_at_time_offset", { time_offset_seconds: timeOffsetSeconds });
  }

  /**
   * Precise seeking with callback handling
   */
  seekToTime(targetTime) {
    this.seekInProgress = true;
    
    // Set target time (absolute source video coordinates)
    this.video.currentTime = targetTime;
    
    // Wait for seek to complete
    const onSeeked = () => {
      this.video.removeEventListener('seeked', onSeeked);
      this.seekInProgress = false;
      
      // Use requestVideoFrameCallback for frame-perfect positioning if available
      if ('requestVideoFrameCallback' in this.video) {
        this.video.requestVideoFrameCallback(() => {
          // Frame is now ready for split operations
        });
      }
    };
    
    this.video.addEventListener('seeked', onSeeked);
  }

  /**
   * Check if currently in split mode
   */
  isSplitModeActive() {
    return this.splitModeActive;
  }

  /**
   * Update clip info (called when clip changes)
   */
  updateClipInfo(clipInfo) {
    this.clipInfo = clipInfo;
  }

  /**
   * Cleanup when component is destroyed
   */
  destroy() {
    this.exitSplitMode();
    this.video = null;
    this.pushEvent = null;
  }
}