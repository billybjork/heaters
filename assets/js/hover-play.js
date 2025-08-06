/**
 * Phoenix LiveView hook for simple video hover-to-play functionality
 * @type {import("phoenix_live_view").Hook}
 */
export const HoverPlay = {
    mounted() {
        this.el.addEventListener("mouseenter", () => {
            this.el.play();
        });

        this.el.addEventListener("mouseleave", () => {
            this.el.pause();
            this.el.currentTime = 0;
        });
    }
};

/**
 * Phoenix LiveView hook for thumbnail hover preview with temp clip styling
 * @type {import("phoenix_live_view").Hook}
 */
export const ThumbHoverPlayer = {
    mounted() {
        const cfg = JSON.parse(this.el.dataset.player);
        this.initVirtualThumb(cfg);
        this.el.addEventListener("mouseenter", () => this.play());
        this.el.addEventListener("mouseleave", () => this.stop());
    },

    /**
     * Initialize virtual thumbnail with temp clip preview styling
     * @param {Object} cfg - Configuration object from data attribute
     */
    initVirtualThumb(cfg) {
        /* temp clip thumbnail - show static preview */
        const THUMB_W = 160;
        this.type = "temp";
        this.w = THUMB_W;
        this.h = Math.round(THUMB_W * 9 / 16); // 16:9 aspect ratio
        this.timer = null;

        /* style element with temp clip preview */
        Object.assign(this.el.style, {
            width: `${this.w}px`,
            height: `${this.h}px`,
            backgroundColor: "#1a1a1a",
            border: "1px solid #0066cc",
            borderRadius: "4px",
            cursor: "pointer",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: "12px",
            color: "#0066cc",
            fontWeight: "500"
        });

        /* show temp clip indicator */
        this.el.innerHTML = `
      <div style="text-align: center; line-height: 1.2;">
        <div style="font-size: 20px;">⚡</div>
        <div style="font-size: 10px; opacity: 0.8;">Temp</div>
      </div>
    `;
    },

    play() {
        /* temp clips: show subtle animation on hover */
        this.el.style.backgroundColor = "#003366";
        this.el.style.transform = "scale(1.05)";
        this.el.style.transition = "all 0.2s ease";
    },

    stop() {
        /* temp clips: reset hover state */
        this.el.style.backgroundColor = "#1a1a1a";
        this.el.style.transform = "scale(1)";
    },

    destroyed() {
        this.stop();
    }
}; 