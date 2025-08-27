/**
 * Frame Navigator - Frame-accurate navigation for video review
 * 
 * Handles precise frame stepping and split operations for virtual subclips.
 * Uses simplified server-side coordinate calculations to eliminate client-side
 * brittleness while maintaining frame-accurate navigation.
 * 
 * Features:
 * - Progressive navigation acceleration: 1x → 2x → 4x → 8x → 16x frame steps
 * - Smart repeat detection within 300ms window
 * - Automatic reset when changing directions or pausing
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
    
    // Progressive navigation acceleration
    this._navigationAcceleration = {
      lastDirection: null,
      repeatCount: 0,
      lastNavigationTime: 0,
      accelerationThreshold: 300, // ms - time window for repeat detection
      accelerationLevels: [1, 2, 4, 8, 16] // frame steps per navigation
    };
  }

  /**
   * Enter split mode - enables frame-accurate navigation
   */
  enterSplitMode(clipInfo) {
    // Defensive check for video element
    if (!this.video) {
      console.error('[FrameNavigator] Cannot enter split mode - video element is null');
      return;
    }
    
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
    this.splitModeActive = false;
    this.seekInProgress = false;
    this.clipInfo = null;
    this._seekAttempts = 0;
    
    // Reset navigation acceleration
    this._navigationAcceleration.lastDirection = null;
    this._navigationAcceleration.repeatCount = 0;
    this._navigationAcceleration.lastNavigationTime = 0;
    
    // Resume playback when exiting split mode (user expectation)
    if (this.video && this.video.paused) {
      this.video.play().catch(e => {
        console.log('[FrameNavigator] Auto-play after split mode failed:', e.message);
      });
    }
    
    // Notify LiveView of split mode change (with error handling)
    try {
      this.pushEvent('split_mode_changed', { active: false });
    } catch (error) {
      console.log('[FrameNavigator] Could not notify LiveView of split mode change:', error.message);
    }
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
    
    // Calculate accelerated frame count based on repeat navigation
    const acceleratedFrameCount = this._calculateAcceleratedFrameCount(direction, frameCount);
    frameCount = acceleratedFrameCount;
    
    // Check if video element exists and is ready for seeking
    if (!this.video) {
      console.error('[FrameNavigator] Frame navigation failed - video element is null');
      return;
    }
    
    if (this.video.readyState < 2) {
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
      return;
    }

    const currentTime = this.video.currentTime;
    const clipStartTime = this.clipInfo?.start_time_seconds || 0;
    const clipEndTime = this.clipInfo?.end_time_seconds || 0;
    
    // Calculate relative time offset from clip start
    const timeOffsetSeconds = currentTime - clipStartTime;
    const clipDuration = clipEndTime - clipStartTime;
    
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
   * Calculate accelerated frame count for rapid navigation
   * Implements progressive speed-up when holding arrow keys
   */
  _calculateAcceleratedFrameCount(direction, baseFrameCount) {
    const now = Date.now();
    const acc = this._navigationAcceleration;
    
    // Check if this is a repeat in the same direction within the threshold
    const isRepeat = acc.lastDirection === direction && 
                    (now - acc.lastNavigationTime) <= acc.accelerationThreshold;
    
    if (isRepeat) {
      // Increase repeat count and accelerate
      acc.repeatCount = Math.min(acc.repeatCount + 1, acc.accelerationLevels.length - 1);
    } else {
      // Reset acceleration for new direction or after pause
      acc.repeatCount = 0;
    }
    
    // Update tracking state
    acc.lastDirection = direction;
    acc.lastNavigationTime = now;
    
    // Calculate accelerated frame count
    const multiplier = acc.accelerationLevels[acc.repeatCount];
    return baseFrameCount * multiplier;
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