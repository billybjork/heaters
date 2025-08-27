/**
 * Review Hotkeys - Keyboard shortcuts for video review interface
 * 
 * Handles keyboard shortcuts for review actions (approve, archive, group, merge, etc.)
 * and integrates with FrameNavigator for split mode operations.
 * 
 * This module focuses purely on keyboard event handling and action dispatch.
 * Frame navigation and coordinate calculations are handled by FrameNavigator.
 */

export default {
  mounted() {
    console.log('[ReviewHotkeys] Mounted');
    
    this.keyMap = {
      'a': 'approve',
      'r': 'archive', 
      'g': 'group',
      'm': 'merge',
      'u': 'undo'
    };

    this.armed = null;     // currently-armed key, e.g. "a"  
    this.btn = null;       // highlighted button element
    this.frameNavigator = null; // Will be set by ClipPlayer
    
    this.setupEventHandlers();
    this.setupSplitModeListener();
    this.connectToClipPlayer();
  },

  destroyed() {
    console.log('[ReviewHotkeys] Destroyed');
    document.removeEventListener('keydown', this._onKeyDown);
    document.removeEventListener('keyup', this._onKeyUp);
  },

  /**
   * Set up keyboard event handlers
   */
  setupEventHandlers() {
    // Key-down handler: manages arming keys and committing actions
    this._onKeyDown = (e) => {
      // Let input fields handle their own keys
      if (['INPUT', 'TEXTAREA', 'SELECT'].includes(e.target.tagName)) {
        return;
      }

      // Let digits go into any input uninterrupted
      if (e.key >= '0' && e.key <= '9') {
        return;
      }

      // Undo – ⌘/Ctrl+Z (UI-level only)
      if ((e.metaKey || e.ctrlKey) && e.key === 'z') {
        this.pushEvent("undo", {});
        e.preventDefault();
        return;
      }

      // Split mode handling
      this.handleSplitModeKeys(e);

      // Review action keys - arm the action for commit with Enter
      const k = e.key.toLowerCase();
      if (this.keyMap[k] && this.armed !== k) {
        this.armed = k;
        this.btn = document.querySelector(`[data-hotkey="${k}"]`);
        
        // Don't arm if button is disabled
        if (this.btn?.disabled) {
          e.preventDefault();
          return;
        }

        this.btn?.classList.add("is-armed");
        e.preventDefault();
        return;
      }

      // ENTER commits the armed action
      if (e.key === "Enter") {
        if (this.armed) {
          const action = this.keyMap[this.armed];
          const payload = { action };
          this.pushEvent("select", payload);
          this._reset();
          e.preventDefault();
        }
      }
    };

    // Key-up handler: clears the button highlight  
    this._onKeyUp = (e) => {
      if (e.key.toLowerCase() === this.armed) {
        this._reset();
      }
    };

    document.addEventListener('keydown', this._onKeyDown);
    document.addEventListener('keyup', this._onKeyUp);
  },

  /**
   * Handle split mode specific keyboard shortcuts
   */
  handleSplitModeKeys(e) {
    // Arrow keys - delegate to FrameNavigator
    if (['ArrowLeft', 'ArrowRight'].includes(e.key)) {
      if (this.frameNavigator) {
        if (!this.frameNavigator.isSplitModeActive()) {
          // Enter split mode on first arrow press
          const clipInfo = this._getClipInfo();
          this.frameNavigator.enterSplitMode(clipInfo);
        }
        
        // Navigate frames
        const direction = e.key === 'ArrowRight' ? 'forward' : 'backward';
        this.frameNavigator.navigateFrames(direction);
        
        e.preventDefault();
        return;
      }
    }

    // Space: toggle split mode
    if (e.key === ' ') {
      if (this.frameNavigator) {
        if (this.frameNavigator.isSplitModeActive()) {
          this.frameNavigator.exitSplitMode();
        } else {
          const clipInfo = this._getClipInfo();
          this.frameNavigator.enterSplitMode(clipInfo);
        }
        e.preventDefault();
        return;
      }
    }

    // Enter: commit split (when in split mode)
    if (e.key === "Enter" && this.frameNavigator?.isSplitModeActive()) {
      this.frameNavigator.commitSplit();
      e.preventDefault();
      return;
    }

    // Escape: exit split mode  
    if (e.key === "Escape" && this.frameNavigator?.isSplitModeActive()) {
      this.frameNavigator.exitSplitMode();
      e.preventDefault();
      return;
    }
  },

  /**
   * Set up listener for split mode changes from LiveView
   */
  setupSplitModeListener() {
    // Register LiveView event handler for split mode changes
    this.handleEvent("split_mode_changed", (payload) => {
      const mainElement = document.querySelector("main");
      const isNowSplitMode = payload.active;
      
      if (isNowSplitMode) {
        mainElement?.classList.add("split-mode-active");
      } else {
        mainElement?.classList.remove("split-mode-active");  
      }
    });
  },

  /**
   * Get clip information from video player for frame calculations
   */
  _getClipInfo() {
    const videoElement = document.querySelector('video[phx-hook="ClipPlayer"]');
    if (videoElement?._clipPlayer) {
      return videoElement._clipPlayer.clipInfo || {};
    }
    return {};
  },

  /**
   * Reset armed state
   */
  _reset() {
    this.armed = null;
    this.btn?.classList.remove("is-armed");
    this.btn = null;
  },

  /**
   * Set frame navigator (called by ClipPlayer)
   */
  setFrameNavigator(frameNavigator) {
    this.frameNavigator = frameNavigator;
    console.log('[ReviewHotkeys] FrameNavigator connected');
  },

  /**
   * Connect to ClipPlayer's FrameNavigator (called after mount)
   */
  connectToClipPlayer() {
    // Give ClipPlayer a moment to initialize, then connect
    setTimeout(() => {
      const videoElement = document.querySelector('video[phx-hook="ClipPlayer"]');
      if (videoElement?._clipPlayer?.getFrameNavigator) {
        this.frameNavigator = videoElement._clipPlayer.getFrameNavigator();
        console.log('[ReviewHotkeys] Connected to FrameNavigator');
      } else {
        console.warn('[ReviewHotkeys] Could not find ClipPlayer FrameNavigator');
      }
    }, 100);
  }
};