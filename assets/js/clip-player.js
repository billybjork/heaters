/**
 * ClipPlayer Hook - Simplified video playback with modular architecture
 * 
 * Core responsibilities:
 * - Video loading and playback management
 * - Integration with FrameNavigator and VirtualControls
 * - LiveView event handling
 * 
 * Complex responsibilities moved to separate modules:
 * - Frame navigation → FrameNavigator
 * - Virtual timeline → VirtualControls  
 * - Split calculations → FrameNavigator
 */

import FrameNavigator from './frame-navigator';
import VirtualControls from './virtual-controls';

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
   * Set up video event handlers
   */
  setupVideoHandlers() {
    this.video.addEventListener('loadedmetadata', () => {
      console.log('[ClipPlayer] Metadata loaded');
      
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
    });

    this.video.addEventListener('timeupdate', () => {
      // Handle virtual clip looping and boundary enforcement
      if (this.playerType === 'virtual_clip' && this.virtualClip) {
        this.handleVirtualSubclipTimeUpdate();
      }
    });

    this.video.addEventListener('canplaythrough', () => {
      console.log('[ClipPlayer] Can play through');
      
      // Don't auto-play in split mode
      if (this.frameNavigator?.isSplitModeActive()) {
        console.log('[ClipPlayer] Ignoring canplaythrough - in split mode');
        return;
      }
      
      this.attemptAutoplay();
    });

    this.video.addEventListener('error', (e) => {
      console.error('[ClipPlayer] Video error:', e);
    });
  },

  /**
   * Load a new video
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
    
    // Update FrameNavigator with new clip info
    this.frameNavigator?.updateClipInfo(this.clipInfo);
    
    // Handle virtual clip URLs that return JSON metadata
    if (playerType === 'virtual_clip') {
      try {
        console.log('[ClipPlayer] Loading virtual clip metadata:', videoUrl);
        const response = await fetch(videoUrl);
        const metadata = await response.json();
        
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
        
        // Load the actual proxy video
        this.video.src = this.virtualClip.proxyUrl;
        
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
   * Switch to a new clip
   */
  async switchClip(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
    console.log(`[ClipPlayer] Switching to new clip: ${videoUrl}`);
    this.video.pause();
    await this.loadVideo(videoUrl, playerType, clipInfo);
  },

  /**
   * Handle virtual clip time boundaries and looping
   */
  handleVirtualSubclipTimeUpdate() {
    if (!this.virtualClip) return;
    
    const currentTime = this.video.currentTime;
    
    // Enforce virtual clip boundaries
    if (currentTime < this.virtualClip.startTime) {
      console.log(`[ClipPlayer] Correcting time: ${currentTime.toFixed(3)}s -> ${this.virtualClip.startTime.toFixed(3)}s (before start)`);
      this.video.currentTime = this.virtualClip.startTime;
      return;
    }
    
    if (currentTime >= this.virtualClip.endTime) {
      // Don't loop in split mode to avoid interfering with frame navigation
      if (this.frameNavigator?.isSplitModeActive()) {
        console.log('[ClipPlayer] End reached in split mode - pausing instead of looping');
        this.video.pause();
        return;
      }
      
      // Auto-loop for normal playback
      console.log(`[ClipPlayer] Virtual clip reached end (${currentTime.toFixed(3)}s >= ${this.virtualClip.endTime.toFixed(3)}s) - looping to start`);
      this.video.currentTime = this.virtualClip.startTime;
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