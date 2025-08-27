// Import CSS first so esbuild can process it
import "../css/app.css"

import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

import { HoverPlay, ThumbHoverPlayer } from "./hover-play";

// Optimized video review system with virtual clip streaming
import ClipPlayer from "./clip-player";     // Handles video playback with debounced time corrections & metadata caching
import ReviewHotkeys from "./review-hotkeys"; // Keyboard shortcuts with frame-accurate navigation support

// Pull the CSRF token from the page
let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content")

// Build the hooks object matching your `phx-hook` names in templates
let Hooks = {
  HoverPlay,
  ThumbHoverPlayer,
  ClipPlayer,
  ReviewHotkeys
}

// Initialise LiveSocket with our hooks and CSRF
let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken }
})

// Connect if any LiveViews are on the page
liveSocket.connect()

// Expose for web console debug  
window.liveSocket = liveSocket