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

    /* geometry – scale every thumb down to 160 px wide, preserving aspect ratio */
    const THUMB_W = 160;
    this.cols = cfg.cols;
    this.rows = cfg.rows;
    const scale = THUMB_W / cfg.tile_width;
    this.w = THUMB_W;
    this.h = Math.round(cfg.tile_height_calculated * scale);

    this.total = cfg.total_sprite_frames;
    /* playback speed = same fps as the big player (capped at 60) */
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

    /* now wire up hover playback */
    this.el.addEventListener("mouseenter", () => this.play());
    this.el.addEventListener("mouseleave", () => this.stop());
  },

  play() {
    if (this.timer) return;
    const interval = 1000 / this.fps;
    this.timer = setInterval(() => this.step(), interval);
  },

  stop() {
    clearInterval(this.timer);
    this.timer = null;
    this.frame = 0;
    this.updateBackground();
  },

  step() {
    this.frame = (this.frame + 1) % this.total;
    this.updateBackground();
  },

  updateBackground() {
    const col = this.frame % this.cols;
    // ← divide by number of *columns* to get the correct row index
    const row = Math.floor(this.frame / this.cols);
    this.el.style.backgroundPosition = `-${col * this.w}px -${row * this.h}px`;
  },

  destroyed() {
    this.stop();
  }
};  