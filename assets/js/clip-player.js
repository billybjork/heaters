/**
 * ClipPlayer Hook - Optimized video playback with virtual clip streaming
 * 
 * Core responsibilities:
 * - Video loading and playback management with proper cleanup
 * - Virtual clip streaming via HTTP Range requests (206 Partial Content)
 * - Integration with FrameNavigator and VirtualControls
 * - LiveView event handling with stale reference prevention
 * 
 * Performance optimizations:
 * - Intelligent metadata caching to prevent duplicate requests
 * - Debounced time corrections (300ms cooldown) to eliminate feedback loops
 * - Proper event handler cleanup to prevent stale time references
 * - Tolerance buffers (0.1s) to reduce excessive boundary corrections
 * 
 * Complex responsibilities moved to separate modules:
 * - Frame navigation → FrameNavigator
 * - Virtual timeline → VirtualControls  
 * - Split calculations → FrameNavigator
 */

import FrameNavigator from './frame-navigator';
import VirtualControls from './virtual-controls';

// Intelligent caching system to optimize network requests
const virtualClipCache = new Map();  // Cache metadata responses to avoid re-fetching
const maxCacheSize = 10;             // LRU eviction when cache exceeds limit

// Request deduplication: prevent multiple parallel requests to same endpoint
const pendingRequests = new Map();

export default {
  mounted() {
    console.log('[ClipPlayer] Mounted');
    
    // Get video element - hook is attached directly to the video element
    this.video = this.el.tagName === 'VIDEO' ? this.el : this.el.querySelector('video');
    if (!this.video) {
      console.error('[ClipPlayer] No video element found');
      return;
    }

    // Parse clip information
    const clipInfoData = this.el.dataset.clipInfo;
    const clipInfo = clipInfoData ? JSON.parse(clipInfoData) : {};

    // Initialize modules
    this.frameNavigator = new FrameNavigator(this.video, (event, payload) => this.pushEvent(event, payload));
    this.virtualControls = null; // Created on demand for virtual clips
    
    // Store state
    this.clipInfo = clipInfo;
    this.playerType = null;
    this.virtualClip = null;
    
    // Debouncing for time corrections to prevent feedback loops
    this.lastCorrectionTime = 0;
    this.correctionCooldown = 300; // ms - prevents time correction cascades that cause excessive looping
    
    // Make accessible to ReviewHotkeys
    this.video._clipPlayer = this;
    
    // FrameNavigator will be accessed by ReviewHotkeys via _clipPlayer reference
    
    // Set up video event handlers
    this.setupVideoHandlers();
    
    // Load initial video if URL is provided
    const videoUrl = this.el.dataset.videoUrl;
    const playerType = this.el.dataset.playerType || 'ffmpeg_stream';
    
    if (videoUrl) {
      this.loadVideo(videoUrl, playerType, clipInfo);
    }

    console.log('[ClipPlayer] Initialized with clip info:', clipInfo);
  },

  destroyed() {
    console.log('[ClipPlayer] Destroying...');
    
    // Clean up event handlers first to prevent stale references
    this.cleanupEventHandlers();
    
    // Clean up modules
    if (this.frameNavigator) {
      this.frameNavigator.destroy();
      this.frameNavigator = null;
    }
    
    if (this.virtualControls) {
      this.virtualControls.destroy();
      this.virtualControls = null;
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
    this.virtualClip = null;
    this.lastCorrectionTime = 0;
  },

  updated() {
    console.log('[ClipPlayer] Updated');
    
    // Handle video URL changes
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
   * CRITICAL: Prevents previous clips' time handlers from interfering with new clips
   */
  cleanupEventHandlers() {
    if (this.eventHandlers && this.video) {
      Object.entries(this.eventHandlers).forEach(([event, handler]) => {
        this.video.removeEventListener(event, handler);
      });
    }
    this.eventHandlers = null;
  },

  /**
   * Set up video event handlers with proper cleanup tracking
   */
  setupVideoHandlers() {
    // Clean up any existing handlers first
    this.cleanupEventHandlers();
    
    // Store event handler references for cleanup
    this.eventHandlers = {
      loadedmetadata: () => {
        console.log('[ClipPlayer] Metadata loaded - video duration:', this.video.duration, 'preload:', this.video.preload);
        
        // Don't interfere with split mode
        if (this.frameNavigator?.isSplitModeActive()) {
          console.log('[ClipPlayer] Ignoring loadedmetadata - in split mode');
          return;
        }
        
        // Set up virtual timeline for virtual clips
        if (this.playerType === 'virtual_clip' && this.virtualClip) {
          console.log(`[ClipPlayer] Virtual clip: setting up virtual timeline`);
          
          if (this.virtualControls) {
            this.virtualControls.destroy();
          }
          
          this.virtualControls = new VirtualControls(this.video, this.virtualClip);
          this.virtualControls.setup();
          
          console.log(`[ClipPlayer] Virtual clip: seeking to start time ${this.virtualClip.startTime}s`);
          this.video.currentTime = this.virtualClip.startTime;
          return;
        }
      },

      timeupdate: () => {
        // Handle virtual clip looping and boundary enforcement
        if (this.playerType === 'virtual_clip' && this.virtualClip) {
          this.handleVirtualSubclipTimeUpdate();
        }
      },

      canplaythrough: () => {
        console.log('[ClipPlayer] Can play through');
        
        // Don't auto-play in split mode
        if (this.frameNavigator?.isSplitModeActive()) {
          console.log('[ClipPlayer] Ignoring canplaythrough - in split mode');
          return;
        }
        
        this.attemptAutoplay();
      },

      error: (e) => {
        console.error('[ClipPlayer] Video error:', e);
      }
    };

    // Add all event listeners
    Object.entries(this.eventHandlers).forEach(([event, handler]) => {
      this.video.addEventListener(event, handler);
    });
  },

  /**
   * Load a new video with proper event handler setup
   */
  async loadVideo(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
    console.log(`[ClipPlayer] Loading video: ${videoUrl} (${playerType})`);
    
    if (this.frameNavigator?.isSplitModeActive()) {
      console.log('[ClipPlayer] WARNING: loadVideo called during split mode - this might reset frame navigation');
    }

    // Store current state
    this.currentVideoUrl = videoUrl;
    this.playerType = playerType;
    this.clipInfo = clipInfo || {};
    
    // Reset debouncing state
    this.lastCorrectionTime = 0;
    
    // Update FrameNavigator with new clip info
    this.frameNavigator?.updateClipInfo(this.clipInfo);
    
    // Set up fresh event handlers for new video
    this.setupVideoHandlers();
    
    // Handle virtual clip URLs that return JSON metadata
    if (playerType === 'virtual_clip') {
      try {
        console.log('[ClipPlayer] Loading virtual clip metadata:', videoUrl);
        
        // Check cache first
        let metadata = virtualClipCache.get(videoUrl);
        if (!metadata) {
          // Check if request is already in-flight
          if (pendingRequests.has(videoUrl)) {
            console.log('[ClipPlayer] Waiting for in-flight request');
            metadata = await pendingRequests.get(videoUrl);
          } else {
            console.log('[ClipPlayer] Fetching metadata from server');
            const requestPromise = fetch(videoUrl).then(r => r.json());
            pendingRequests.set(videoUrl, requestPromise);
            
            try {
              metadata = await requestPromise;
              // Cache the metadata
              virtualClipCache.set(videoUrl, metadata);
              
              // Enforce cache size limit
              if (virtualClipCache.size > maxCacheSize) {
                const firstKey = virtualClipCache.keys().next().value;
                virtualClipCache.delete(firstKey);
              }
            } finally {
              pendingRequests.delete(videoUrl);
            }
          }
        } else {
          console.log('[ClipPlayer] Using cached metadata');
        }
        
        if (metadata.type !== 'virtual_clip') {
          throw new Error(`Expected virtual_clip metadata, got ${metadata.type}`);
        }
        
        // Store virtual clip data
        this.virtualClip = {
          proxyUrl: metadata.proxy_url,
          startTime: parseFloat(metadata.start_time),
          endTime: parseFloat(metadata.end_time), 
          duration: parseFloat(metadata.duration),
          clipId: metadata.clip_id
        };
        
        console.log('[ClipPlayer] Virtual clip loaded:', this.virtualClip);
        console.log('[ClipPlayer] About to set video src, current preload setting:', this.video.preload);
        
        // Load the actual proxy video with controlled loading
        this.video.src = this.virtualClip.proxyUrl;
        
        // For virtual clips with preload=metadata, we want to minimize duplicate requests
        // The browser may make two requests: one for metadata, one for playback
        // This is normal behavior and actually efficient for seeking
        console.log('[ClipPlayer] Virtual clip src set, preload strategy:', this.video.preload);
        
      } catch (error) {
        console.error('[ClipPlayer] Failed to load virtual clip:', error);
        throw error;
      }
    } else {
      // Regular video loading
      this.virtualClip = null;
      this.video.src = videoUrl;
    }
  },

  /**
   * Switch to a new clip with proper cleanup
   */
  async switchClip(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
    console.log(`[ClipPlayer] Switching to new clip: ${videoUrl}`);
    
    // Clean slate: reset all state before loading new clip
    this.video.pause();
    this.virtualClip = null;
    this.lastCorrectionTime = 0;
    
    // Clean up existing handlers to prevent stale references
    this.cleanupEventHandlers();
    
    await this.loadVideo(videoUrl, playerType, clipInfo);
  },

  /**
   * Handle virtual clip time boundaries and looping with debouncing
   */
  handleVirtualSubclipTimeUpdate() {
    if (!this.virtualClip) return;
    
    const currentTime = this.video.currentTime;
    const now = Date.now();
    
    // Define tolerances to reduce excessive corrections
    const startTolerance = 0.1; // Allow 0.1s before clip start
    const endTolerance = 0.1;    // Allow 0.1s after clip end before looping (increased for stability)
    
    // Enforce virtual clip boundaries with debouncing
    if (currentTime < (this.virtualClip.startTime - startTolerance)) {
      // Debounce corrections to prevent cascade
      if (now - this.lastCorrectionTime > this.correctionCooldown) {
        console.log(`[ClipPlayer] Correcting time: ${currentTime.toFixed(3)}s -> ${this.virtualClip.startTime.toFixed(3)}s (significantly before start)`);
        this.video.currentTime = this.virtualClip.startTime;
        this.lastCorrectionTime = now;
      }
      return;
    }
    
    if (currentTime >= (this.virtualClip.endTime + endTolerance)) {
      // Don't loop in split mode to avoid interfering with frame navigation
      if (this.frameNavigator?.isSplitModeActive()) {
        console.log('[ClipPlayer] End reached in split mode - pausing instead of looping');
        this.video.pause();
        return;
      }
      
      // Debounce looping to prevent rapid loops  
      if (now - this.lastCorrectionTime > this.correctionCooldown) {
        console.log(`[ClipPlayer] Virtual clip reached end (${currentTime.toFixed(3)}s >= ${(this.virtualClip.endTime + endTolerance).toFixed(3)}s) - looping to start`);
        this.video.currentTime = this.virtualClip.startTime;
        this.lastCorrectionTime = now;
      } else {
        // Suppress additional loop attempts during cooldown
        console.log(`[ClipPlayer] Loop suppressed (cooldown active: ${now - this.lastCorrectionTime}ms < ${this.correctionCooldown}ms)`);
      }
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
   * Public API for accessing frame navigator (used by ReviewHotkeys)
   */
  getFrameNavigator() {
    return this.frameNavigator;
  }
};