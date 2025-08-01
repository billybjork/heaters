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

export const ThumbHoverPlayer = {
    mounted() {
        const cfg = JSON.parse(this.el.dataset.player);
        this.initVirtualThumb(cfg);
        this.el.addEventListener("mouseenter", () => this.play());
        this.el.addEventListener("mouseleave", () => this.stop());
    },

    initVirtualThumb(cfg) {
        /* virtual clip thumbnail - show static preview */
        const THUMB_W = 160;
        this.type = "virtual";
        this.w = THUMB_W;
        this.h = Math.round(THUMB_W * 9 / 16); // 16:9 aspect ratio
        this.timer = null;

        /* style element with virtual clip preview */
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

        /* show virtual clip indicator */
        this.el.innerHTML = `
      <div style="text-align: center; line-height: 1.2;">
        <div style="font-size: 20px;">⚡</div>
        <div style="font-size: 10px; opacity: 0.8;">Virtual</div>
      </div>
    `;
    },

    play() {
        /* virtual clips: show subtle animation on hover */
        this.el.style.backgroundColor = "#003366";
        this.el.style.transform = "scale(1.05)";
        this.el.style.transition = "all 0.2s ease";
    },

    stop() {
        /* virtual clips: reset hover state */
        this.el.style.backgroundColor = "#1a1a1a";
        this.el.style.transform = "scale(1)";
    },

    destroyed() {
        this.stop();
    }
}; 