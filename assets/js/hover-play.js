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

    /* detect clip type and initialize appropriate player */
    if (cfg.is_virtual) {
      this.initVirtualThumb(cfg);
    } else {
      this.initSpriteThumb(cfg);
    }

    /* now wire up hover playback */
    this.el.addEventListener("mouseenter", () => this.play());
    this.el.addEventListener("mouseleave", () => this.stop());
  },

  initSpriteThumb(cfg) {
    /* sprite-based thumbnail for physical clips */
    const THUMB_W = 160;
    this.type = "sprite";
    this.cols = cfg.cols;
    this.rows = cfg.rows;
    const scale = THUMB_W / cfg.tile_width;
    this.w = THUMB_W;
    this.h = Math.round(cfg.tile_height_calculated * scale);

    this.total = cfg.total_sprite_frames;
    this.fps = Math.min(60, cfg.clip_fps || 24);
    this.frame = 0;
    this.timer = null;

    /* style element */
    Object.assign(this.el.style, {
      width: `${this.w}px`,
      height: `${this.h}px`,
      backgroundImage: `url("${cfg.spriteUrl}")`,
      backgroundRepeat: "no-repeat",
      backgroundSize: `${this.w * this.cols}px auto`,
      backgroundPosition: "0 0",
      cursor: "pointer"
    });
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
    if (this.type === "sprite" && !this.timer) {
    const interval = 1000 / this.fps;
    this.timer = setInterval(() => this.step(), interval);
    } else if (this.type === "virtual") {
      /* virtual clips: show subtle animation on hover */
      this.el.style.backgroundColor = "#003366";
      this.el.style.transform = "scale(1.05)";
      this.el.style.transition = "all 0.2s ease";
    }
  },

  stop() {
    if (this.type === "sprite") {
    clearInterval(this.timer);
    this.timer = null;
    this.frame = 0;
    this.updateBackground();
    } else if (this.type === "virtual") {
      /* virtual clips: reset hover state */
      this.el.style.backgroundColor = "#1a1a1a";
      this.el.style.transform = "scale(1)";
    }
  },

  step() {
    if (this.type === "sprite") {
    this.frame = (this.frame + 1) % this.total;
    this.updateBackground();
    }
  },

  updateBackground() {
    if (this.type === "sprite") {
    const col = this.frame % this.cols;
    const row = Math.floor(this.frame / this.cols);
    this.el.style.backgroundPosition = `-${col * this.w}px -${row * this.h}px`;
    }
  },

  destroyed() {
    this.stop();
  }
};  