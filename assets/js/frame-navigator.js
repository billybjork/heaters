/**
 * Frame Navigator - Frame-accurate navigation for video review
 * 
 * Handles precise frame stepping, split operations, and coordinate system translation
 * for virtual subclips. This is the most critical part of the split functionality.
 * 
 * COORDINATE SYSTEM DOCUMENTATION:
 * This module handles the complex translation between three coordinate systems:
 * 1. Source Video (absolute) - Database storage, cuts, validation
 * 2. Virtual Subclip (relative) - UI timeline, user interaction  
 * 3. Video Element (absolute source time) - video.currentTime, seeking
 * 
 * CRITICAL: video.currentTime is ALWAYS absolute source video time!
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
   * CRITICAL: Frame Navigation for Virtual Subclips
   * 
   * Implements precise frame stepping using database FPS data for split mode.
   * This function works with ABSOLUTE source video time coordinates.
   * 
   * COORDINATE HANDLING:
   * - this.video.currentTime is ALWAYS absolute source video time
   * - frameTime = 1/fps gives the time delta for one frame
   * - targetTime = currentTime +/- frameTime stays in absolute coordinates
   * - Virtual subclip boundaries are handled by timeupdate event handlers
   * 
   * EXAMPLE:
   * - Clip spans 33.292s-35.708s in source video @ 24fps
   * - frameTime = 1/24 = 0.04167s per frame
   * - Current position: video.currentTime = 34.5s (absolute)
   * - Step forward: targetTime = 34.5s + 0.04167s = 34.54167s (still absolute)
   * - Split calculation later: (34.54167s - 33.292s) * 24fps + 799 = frame 829
   * 
   * This maintains consistency with the virtual subclip coordinate system
   * and enables accurate split frame calculations.
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

    const fps = this.clipInfo?.fps || 30.0;
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
   * Commit split at current video position
   * 
   * Handles the complex coordinate translation from absolute video time
   * to absolute frame number for the split operation.
   */
  commitSplit() {
    if (!this.splitModeActive) {
      console.log('[FrameNavigator] Split commit ignored - not in split mode');
      return;
    }

    const currentTime = this.video.currentTime;
    const fps = this.clipInfo?.fps || 30.0; 
    const clipStartFrame = this.clipInfo?.start_frame || 0;
    const clipStartTime = this.clipInfo?.start_time_seconds || 0;
    
    /**
     * CRITICAL: Virtual Subclip Coordinate System Documentation
     * 
     * Virtual subclips use HTTP Range requests to stream video segments without
     * creating temp files. This creates a complex coordinate system that MUST
     * be handled correctly to avoid split operation failures.
     * 
     * COORDINATE SYSTEMS:
     * 1. Source Video Coordinates (absolute):
     *    - Time: 0s to video.duration_seconds (e.g., 50s video)
     *    - Frames: 0 to (duration * fps) (e.g., 0-1200 @ 24fps)
     * 
     * 2. Virtual Subclip Coordinates (relative to clip start):
     *    - Time: 0s to clip.duration_seconds (e.g., 0-2.4s for short clip)
     *    - Frames: 0 to clip frame count (e.g., 0-58 frames)
     * 
     * 3. Database Clip Coordinates (absolute source positions):
     *    - start_time_seconds: 33.292s (absolute time in source)
     *    - end_time_seconds: 35.708s (absolute time in source)  
     *    - start_frame: 799 (absolute frame in source)
     *    - end_frame: 857 (absolute frame in source)
     * 
     * KEY INSIGHT: video.currentTime for virtual subclips is ABSOLUTE SOURCE TIME!
     * 
     * EXAMPLE CALCULATION:
     * - Clip spans frames 799-857 (time 33.292s-35.708s) in source video
     * - User seeks to middle: video.currentTime = 34.5s (ABSOLUTE source time)
     * - Split calculation:
     *   1. relativeTime = 34.5s - 33.292s = 1.208s (relative to clip start)
     *   2. relativeFrame = 1.208s * 24fps = 29 frames (relative to clip start)
     *   3. absoluteFrame = 799 + 29 = 828 (absolute frame in source - CORRECT)
     * 
     * WRONG CALCULATION (old bug):
     *   absoluteFrame = 34.5s * 24fps = 828, then + 799 = 1627 (way outside clip!)
     * 
     * This coordinate translation is the most fragile part of virtual subclips.
     * Any changes to video.currentTime handling MUST preserve this logic.
     */
    const relativeTime = currentTime - clipStartTime;
    const relativeFrameNumber = Math.round(relativeTime * fps);
    const absoluteFrameNumber = clipStartFrame + relativeFrameNumber;

    // Bounds checking for robustness
    const clipEndFrame = this.clipInfo.end_frame || (clipStartFrame + Math.round((this.clipInfo.duration_seconds || 1) * fps));
    
    console.log(`[FrameNavigator] Split frame calculation:
  Video time: ${currentTime.toFixed(3)}s
  Clip start: ${clipStartTime}s (frame ${clipStartFrame})
  Relative time: ${relativeTime.toFixed(3)}s
  Calculated frame: ${absoluteFrameNumber} (within ${clipStartFrame}-${clipEndFrame})`);

    if (absoluteFrameNumber <= clipStartFrame || absoluteFrameNumber >= clipEndFrame) {
      console.warn(`[FrameNavigator] Frame ${absoluteFrameNumber} is outside clip boundaries ${clipStartFrame}-${clipEndFrame}, skipping split`);
      return;
    }

    this.pushEvent("split_at_frame", { frame_number: absoluteFrameNumber });
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