/**
 * Phoenix LiveView hook for keyboard review actions
 * @type {import("phoenix_live_view").Hook}
 *
 * Keyboard shortcuts for review workflow:
 *   ┌─────────────┬────────┐
 *   │ Letter-key  │ Action │
 *   ├─────────────┼────────┤
 *   │  A          │ approve│
 *   │  S          │ skip   │
 *   │  D          │ archive│
 *   │  F          │ merge  │
 *   │  G          │ group  │
 *   │  Space      │ split  │
 *   └─────────────┴────────┘
 *
 * Split mode navigation:
 *   - Space: toggle split mode
 *   - Left/Right arrows: navigate frames (when in split mode)
 *   - Enter: commit split at current frame (when in split mode)
 *   - Escape: exit split mode
 *
 * Usage:
 *  - Hold a letter → the corresponding button highlights (is-armed)
 *  - Press ENTER while a letter is armed → commits the action
 *  - Press ⌘/Ctrl+Z to undo the last action (UI-level only)
 */
export default {
    mounted() {
        console.log("[ReviewHotkeys] Hook mounted");
        // Map single-letter keys to their respective actions
        this.keyMap = { a: "approve", s: "skip", d: "archive", f: "merge", g: "group" };
        this.armed = null;             // currently-armed key, e.g. "a"
        this.btn = null;             // highlighted button element
        this.splitMode = false;            // whether split mode is active

        // Register LiveView event handler for split mode changes
        // CRITICAL: Use this.handleEvent() not custom handleEvent method (causes conflicts)
        this.handleEvent("split_mode_changed", (payload) => {
            this._onSplitModeChanged(payload);
        });

        // Key-down handler: manages arming keys and committing actions
        this._onKeyDown = (e) => {
            const tag = (e.target.tagName || "").toLowerCase();
            const k = e.key.toLowerCase();

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

            // Split mode handling
            if (this._isInSplitMode()) {
                this._handleSplitModeKeys(e, k);
                return;
            }

            // Arrow keys - enter split mode if not already in it, or navigate if in split mode
            if (k === "arrowleft" || k === "arrowright") {
                const mainElement = document.querySelector("#review");
                const isCurrentlyInSplitMode = mainElement?.classList.contains("split-mode-active");

                if (!isCurrentlyInSplitMode) {
                    // Enter split mode and control ClipPlayer directly
                    this.pushEvent("toggle_split_mode", {});
                    this._enterSplitMode();
                    e.preventDefault();
                    return;
                }

                // Already in split mode - navigate frames directly
                this._navigateFrames(k === "arrowleft" ? "backward" : "forward");
                e.preventDefault();
                return;
            }

            // 1) First press of A/S/D/G/F → arm and highlight (if button is not disabled)
            if (this.keyMap[k] && !this.armed) {
                if (e.repeat) { e.preventDefault(); return; }
                const targetBtn = document.getElementById(`btn-${this.keyMap[k]}`);

                // Don't arm if button is disabled
                if (targetBtn?.disabled) {
                    e.preventDefault();
                    return;
                }

                this.armed = k;
                this.btn = targetBtn;
                this.btn?.classList.add("is-armed");
                e.preventDefault();
                return;
            }

            // 2) ENTER commits the armed action
            if (e.key === "Enter") {
                // If a letter is armed, commit that action
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

        window.addEventListener("keydown", this._onKeyDown);
        window.addEventListener("keyup", this._onKeyUp);
    },

    updated() {
        // Check if split mode state changed in the DOM
        const mainElement = document.querySelector("#review");
        if (mainElement) {
            const isNowSplitMode = mainElement.classList.contains("split-mode-active");
            if (isNowSplitMode !== this.splitMode) {
                this.splitMode = isNowSplitMode;
                console.log("[ReviewHotkeys] Split mode updated from DOM:", this.splitMode);
            }
        }
    },

    destroyed() {
        window.removeEventListener("keydown", this._onKeyDown);
        window.removeEventListener("keyup", this._onKeyUp);
    },

    // Handle split mode change events from LiveView
    _onSplitModeChanged(payload) {
        console.log("[ReviewHotkeys] Received split_mode_changed event:", payload);

        if (!payload.split_mode) {
            // Exiting split mode - restore ClipPlayer
            console.log("[ReviewHotkeys] Exiting split mode - restoring ClipPlayer");
            this._exitSplitMode();
        }

        this.splitMode = payload.split_mode;
        console.log("[ReviewHotkeys] Split mode updated from LiveView:", this.splitMode);
    },

    // Check current split mode from DOM (more reliable than internal state)
    _isInSplitMode() {
        const mainElement = document.querySelector("#review");
        return mainElement?.classList.contains("split-mode-active") || false;
    },

    // Simple direct ClipPlayer control methods
    _enterSplitMode() {
        console.log("[ReviewHotkeys] Entering split mode - finding ClipPlayer");
        const video = document.querySelector(".video-player");
        if (video && video._clipPlayer) {
            video._clipPlayer.enterSplitMode();
            console.log("[ReviewHotkeys] ClipPlayer enterSplitMode called");
        } else {
            console.log("[ReviewHotkeys] ClipPlayer not found or not ready");
        }
    },

    _exitSplitMode() {
        console.log("[ReviewHotkeys] Exiting split mode - restoring ClipPlayer");
        const video = document.querySelector(".video-player");
        if (video && video._clipPlayer) {
            video._clipPlayer.exitSplitMode();
            console.log("[ReviewHotkeys] ClipPlayer exitSplitMode called");
        }
    },

    _navigateFrames(direction) {
        const video = document.querySelector(".video-player");
        if (video && video._clipPlayer) {
            video._clipPlayer.navigateFrames(direction);
        }
    },

    // Handle split mode keyboard navigation
    _handleSplitModeKeys(e, k) {

        // Arrow keys for frame navigation directly
        if (k === "arrowleft" || k === "arrowright") {
            const direction = k === "arrowleft" ? "backward" : "forward";
            this._navigateFrames(direction);
            e.preventDefault();
            return;
        }

        // Escape exits split mode
        if (e.key === "Escape") {
            this.pushEvent("toggle_split_mode", {});
            this._exitSplitMode();
            e.preventDefault();
            return;
        }

        // Enter commits split at current frame
        if (e.key === "Enter") {
            // Get current video time for frame calculation
            const video = document.querySelector(".video-player");
            if (video) {
                const currentTime = video.currentTime;
                
                // Get clip info including DB fps
                const clipInfo = this._getClipInfo();
                const fps = clipInfo?.fps || 30.0; // Use DB fps with fallback
                const clipStartFrame = clipInfo ? clipInfo.start_frame || 0 : 0;
                const relativeFrameNumber = Math.round(currentTime * fps);
                const absoluteFrameNumber = clipStartFrame + relativeFrameNumber;

                this.pushEvent("split_at_frame", { frame_number: absoluteFrameNumber });
            }
            e.preventDefault();
            return;
        }
    },


    // Get clip information from video player
    _getClipInfo() {
        const videoElement = document.querySelector('video[phx-hook="ClipPlayer"]');
        if (videoElement && videoElement.dataset.clipInfo) {
            try {
                return JSON.parse(videoElement.dataset.clipInfo);
            } catch (error) {
                console.error("Failed to parse clip info:", error);
            }
        }
        return null;
    },

    // Reset armed state and button highlight
    _reset() {
        this.btn?.classList.remove("is-armed");
        this.armed = this.btn = null;
    }
};
