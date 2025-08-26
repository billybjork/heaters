/**
 * Virtual Controls - Custom video controls for virtual clips
 * 
 * Replaces native browser controls with custom timeline that shows
 * virtual clip duration instead of full source video duration.
 * Handles the coordinate translation between virtual and absolute time.
 */

export default class VirtualControls {
  constructor(video, virtualClip) {
    this.video = video;
    this.virtualClip = virtualClip;
    this.controlsContainer = null;
    this.virtualProgressBar = null;
    this.virtualTimeDisplay = null;
  }

  /**
   * Set up virtual timeline controls
   */
  setup() {
    console.log(`[VirtualControls] Setting up virtual timeline (${this.virtualClip.duration}s duration)`);
    
    // Hide native controls to replace with virtual ones
    this.video.controls = false;
    
    this.createVirtualControls();
    this.setupEventHandlers();
  }

  /**
   * Create custom control elements
   */
  createVirtualControls() {
    // Create controls container
    this.controlsContainer = document.createElement('div');
    this.controlsContainer.innerHTML = `
      <div class="virtual-controls-bar">
        <button class="virtual-play-pause">▶</button>
        <div class="virtual-timeline">
          <input type="range" class="virtual-progress" min="0" max="${this.virtualClip.duration}" step="0.1" value="0">
          <span class="virtual-time">0:00 / ${this.formatTime(this.virtualClip.duration)}</span>
        </div>
      </div>
    `;
    
    // Add styles
    const style = document.createElement('style');
    style.textContent = `
      .virtual-controls-container {
        position: absolute;
        bottom: 0;
        left: 0;
        right: 0;
        background: linear-gradient(transparent, rgba(0,0,0,0.5));
        padding: 10px;
        z-index: 10;
      }
      .virtual-controls-bar {
        display: flex;
        align-items: center;
        gap: 10px;
      }
      .virtual-play-pause {
        background: none;
        border: none;
        color: white;
        font-size: 18px;
        cursor: pointer;
      }
      .virtual-timeline {
        flex: 1;
        display: flex;
        align-items: center;
        gap: 10px;
      }
      .virtual-progress {
        flex: 1;
        height: 4px;
        background: rgba(255,255,255,0.3);
        outline: none;
        cursor: pointer;
      }
      .virtual-time {
        color: white;
        font-size: 12px;
        min-width: 80px;
      }
    `;
    
    this.controlsContainer.className = 'virtual-controls-container';
    
    // Insert controls into video container
    const container = this.video.parentElement;
    if (container) {
      container.style.position = 'relative';
      container.appendChild(this.controlsContainer);
      container.appendChild(style);
    }
  }

  /**
   * Set up control event handlers
   */
  setupEventHandlers() {
    if (!this.controlsContainer) return;
    
    const playPauseBtn = this.controlsContainer.querySelector('.virtual-play-pause');
    const progressBar = this.controlsContainer.querySelector('.virtual-progress');
    const timeDisplay = this.controlsContainer.querySelector('.virtual-time');
    
    // Store references for updating from main timeupdate handler
    this.virtualProgressBar = progressBar;
    this.virtualTimeDisplay = timeDisplay;
    
    // Play/pause button
    playPauseBtn.addEventListener('click', () => {
      if (this.video.paused) {
        this.video.play();
      } else {
        this.video.pause();
      }
    });
    
    // Progress bar seeking - CRITICAL COORDINATE TRANSLATION
    progressBar.addEventListener('input', (e) => {
      const virtualTime = parseFloat(e.target.value);  // 0 to clip.duration_seconds (relative)
      const actualTime = this.virtualClip.startTime + virtualTime;  // Convert to absolute source time
      
      // IMPORTANT: This sets video.currentTime to ABSOLUTE source video time!
      // This is why frame calculations must subtract clipStartTime before calculating frames.
      // Example: virtualTime=1.2s + startTime=33.292s = actualTime=34.492s (absolute)
      this.video.currentTime = actualTime;
    });
    
    // Update play/pause button state
    this.video.addEventListener('play', () => {
      playPauseBtn.textContent = '⏸';
    });
    
    this.video.addEventListener('pause', () => {
      playPauseBtn.textContent = '▶';
    });

    // Handle timeupdate to keep virtual controls in sync
    this.video.addEventListener('timeupdate', () => {
      this.updateVirtualTimeDisplay();
    });
  }

  /**
   * Update virtual timeline display
   * Called from video timeupdate events
   */
  updateVirtualTimeDisplay() {
    if (!this.virtualProgressBar || !this.virtualTimeDisplay) return;

    // Convert absolute video time to virtual timeline position
    const currentAbsoluteTime = this.video.currentTime;
    const virtualTime = Math.max(0, Math.min(
      currentAbsoluteTime - this.virtualClip.startTime,
      this.virtualClip.duration
    ));

    // Update progress bar (0 to duration)
    this.virtualProgressBar.value = virtualTime;
    
    // Update time display
    this.virtualTimeDisplay.textContent = 
      `${this.formatTime(virtualTime)} / ${this.formatTime(this.virtualClip.duration)}`;
  }

  /**
   * Format seconds as MM:SS
   */
  formatTime(seconds) {
    const mins = Math.floor(seconds / 60);
    const secs = Math.floor(seconds % 60);
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  }

  /**
   * Clean up virtual controls
   */
  destroy() {
    if (this.controlsContainer) {
      this.controlsContainer.remove();
      this.controlsContainer = null;
    }

    // Restore native controls
    this.video.controls = true;
    
    this.virtualProgressBar = null;
    this.virtualTimeDisplay = null;
  }
}