/**
 * Split-mode state management for Clip Review
 * ──────────────────────────────────────────────────────────────────────────
 * Global state machine for split functionality - manages entering/exiting
 * split mode, frame selection, and UI state coordination.
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
    pushFn("select", {
      action: "split",
      frame: this.activePlayer.currentFrame
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