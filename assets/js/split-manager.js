/**
 * Split-mode state management for Clip Review
 * ──────────────────────────────────────────────────────────────────────────
 * Global state machine for split functionality - manages entering/exiting
 * split mode, frame selection, and UI state coordination.
 * 
 * FRAME INDEXING SYSTEM: PURE CLIP-RELATIVE
 * - Frontend (UI): 1-indexed clip-relative frames (frame 1, 2, 3... up to total_frames-1)
 * - Backend validation: Same 1-indexed clip-relative frames against clip duration
 * - No conversion needed: clipRelativeFrame passed directly to backend
 * - Valid split range: 2 to (total_frames - 1) (prevents zero-duration segments)
 * 
 * FRAME CALCULATION CONSISTENCY FIX:
 * - Frontend uses clip_total_frames from sprite metadata (calculated with video FPS)
 * - Backend validation now uses same FPS priority logic as sprite metadata
 * - This ensures frontend and backend calculate identical valid frame ranges
 * - Eliminates "Split frame X is outside clip range" errors from FPS mismatches
 */

export const SplitManager = {
  splitMode: false,
  activePlayer: null,
  btnEl: null,

  /** Enter split mode: pause playback, highlight UI. */
  enter(player, btn) {
    this.splitMode = true;
    this.activePlayer = player;
    this.btnEl = btn;

    player.pause("split-enter");
    btn?.classList.add("split-armed");
    player.viewerEl.classList.add("split-armed");
  },

  /** Exit without committing. */
  exit() {
    if (!this.splitMode) return;
    this.btnEl?.classList.remove("split-armed");
    this.activePlayer.viewerEl.classList.remove("split-armed");
    this.activePlayer.play("split-exit");

    this.splitMode = false;
    this.activePlayer = null;
    this.btnEl = null;
  },

  /** Commit the chosen frame – pushes a `"select"` event and resets state. */
  commit(pushFn) {
    if (!this.splitMode || !this.activePlayer) return;
    
    // Use pure clip-relative frames - no conversion needed
    // Backend validation expects: 1 < split_frame < clip_total_frames
    // Note: Cannot split at frame 1 or last frame (would create zero-duration segments)
    const clipRelativeFrame = this.activePlayer.currentFrame;
    const totalFrames = this.activePlayer.meta.clip_total_frames || 0;
    
    // Enhanced debug logging to understand frame calculation
    console.log(`Split validation debug:`, {
      clipRelativeFrame,
      totalFrames,
      validRange: `${2}-${totalFrames - 1}`,
      meta: this.activePlayer.meta,
      clipId: this.activePlayer.clipId,
      fps: this.activePlayer.meta.clip_fps,
      fpsSource: this.activePlayer.meta.clip_fps_source,
      totalSpriteFrames: this.activePlayer.meta.total_sprite_frames
    });
    
    // Add robust frontend validation to prevent invalid splits
    if (clipRelativeFrame <= 1 || clipRelativeFrame >= totalFrames) {
      console.warn(`Invalid split frame ${clipRelativeFrame}: must be between 2 and ${totalFrames - 1}`);
      alert(`Cannot split at frame ${clipRelativeFrame}. Please select a frame between 2 and ${totalFrames - 1}.`);
      return; // Don't send invalid split requests
    }
    
    console.log(`Split: Sending valid split request for frame ${clipRelativeFrame} (range: 2-${totalFrames - 1})`);
    
    pushFn("select", {
      action: "split",
      frame: clipRelativeFrame
    });
    this.exit();
  },

  /** Nudge frame cursor left / right while armed. */
  nudge(delta) {
    if (!this.splitMode || !this.activePlayer) return;
    const next = this.activePlayer.currentFrame + delta;
    this.activePlayer.updateFrame(next, true);
  }
};