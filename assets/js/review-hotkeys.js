// Phoenix LiveView hook for keyboard review actions (virtual clips only)
//
//   ┌─────────────┬────────┐
//   │ Letter-key  │ Action │
//   ├─────────────┼────────┤
//   │  A          │ approve│
//   │  S          │ skip   │
//   │  D          │ archive│
//   │  G          │ group  │
//   └─────────────┴────────┘
//
// Overview:
//  * Hold a letter → the corresponding button highlights (is-armed).
//  * Press ENTER while a letter is armed → commits the action.
//  * Press ⌘/Ctrl+Z to undo the last action (UI-level only).

export const ReviewHotkeys = {
  mounted() {
    // Map single-letter keys to their respective actions
    this.keyMap    = { a: "approve", s: "skip", d: "archive", g: "group" };
    this.armed     = null;             // currently-armed key, e.g. "a"
    this.btn       = null;             // highlighted button element

    // Key-down handler: manages arming keys and committing actions
    this._onKeyDown = (e) => {
      const tag  = (e.target.tagName || "").toLowerCase();
      const k    = e.key.toLowerCase();

      // Let digits go into any input uninterrupted
      if (tag === "input") {
        return;
      }

      // Undo – ⌘/Ctrl+Z (UI-level only)
      if ((e.metaKey || e.ctrlKey) && k === "z") {
        this.pushEvent("undo", {});
        this._reset();
        e.preventDefault();
        return;
      }

      // 1) First press of A/S/D/G → arm and highlight
      if (this.keyMap[k] && !this.armed) {
        if (e.repeat) { e.preventDefault(); return; }
        this.armed = k;
        this.btn   = document.getElementById(`btn-${this.keyMap[k]}`);
        this.btn?.classList.add("is-armed");
        e.preventDefault();
        return;
      }

      // 2) ENTER commits the armed action
      if (e.key === "Enter") {
        // If a letter is armed, commit that action
        if (this.armed) {
          const action  = this.keyMap[this.armed];
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

    window.addEventListener("keydown", this._onKeyDown);
    window.addEventListener("keyup",   this._onKeyUp);
  },

  destroyed() {
    window.removeEventListener("keydown", this._onKeyDown);
    window.removeEventListener("keyup",   this._onKeyUp);
  },

  // Reset armed state and button highlight
  _reset() {
    this.btn?.classList.remove("is-armed");
    this.armed = this.btn = null;
  }
};