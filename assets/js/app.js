import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

import { ReviewHotkeys } from "./review-hotkeys"
import { StreamingVideoPlayerController } from "./streaming-video-player-controller"
import { HoverPlay, ThumbHoverPlayer } from "./hover-play";

// Pull the CSRF token from the page
let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content")

// Debug logging
console.log("[DEBUG] Imported StreamingVideoPlayerController:", typeof StreamingVideoPlayerController);

// Build the hooks object matching your `phx-hook` names in templates
let Hooks = {
  ReviewHotkeys,
  StreamingVideoPlayer: StreamingVideoPlayerController,
  ThumbHoverPlayer,
  HoverPlay
}

console.log("[DEBUG] Hooks object:", Object.keys(Hooks));

// Initialise LiveSocket with our hooks and CSRF
let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken }
})

console.log("[DEBUG] LiveSocket created with hooks:", Object.keys(liveSocket.opts.hooks || {}));

// Connect if any LiveViews are on the page
liveSocket.connect()

// Expose for web console debug
window.liveSocket = liveSocket

console.log("[DEBUG] LiveSocket assigned to window, hooks:", Object.keys(window.liveSocket?.opts?.hooks || {}));