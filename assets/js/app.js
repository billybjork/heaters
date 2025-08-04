// Import CSS first so esbuild can process it
import "../css/app.css"

import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

import { ReviewHotkeys } from "./review-hotkeys"
import { ClipPlayerController } from "./clip-player-controller"
import { HoverPlay, ThumbHoverPlayer } from "./hover-play";
import { ClipPlayer } from "./clip-player";

// Pull the CSRF token from the page
let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content")

// Debug logging
console.log("[DEBUG] Imported ClipPlayerController:", typeof ClipPlayerController);

// Build the hooks object matching your `phx-hook` names in templates
let Hooks = {
  ReviewHotkeys,
  ClipPlayer: ClipPlayerController,
  HoverPlay,
  ThumbHoverPlayer
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
window.ClipPlayer = ClipPlayer

console.log("[DEBUG] LiveSocket assigned to window, hooks:", Object.keys(window.liveSocket?.opts?.hooks || {}));