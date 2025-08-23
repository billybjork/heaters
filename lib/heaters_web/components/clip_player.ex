defmodule HeatersWeb.ClipPlayer do
  @moduledoc """
  Phoenix LiveView component for clip playback using colocated hooks architecture.

  This is a **single-file component** that demonstrates Phoenix LiveView 1.1's
  colocated hooks feature. All JavaScript functionality is embedded directly in
  this component file, eliminating the need for separate JS files.

  ## Key Features

  - **Single-File Architecture**: Elixir, HEEx, and JavaScript in one file
  - **Automatic Namespacing**: Hook name `.ClipPlayer` is prefixed with module name
  - **Instant Playback**: Small files (2-5MB) generated on-demand using FFmpeg stream copy
  - **Perfect Timeline**: Shows exact clip duration, not full video length
  - **Zero Re-encoding**: Stream copy ensures fastest generation with zero quality loss
  - **Universal Compatibility**: Works offline, all browsers, mobile optimized
  - **Reactive Updates**: Phoenix LiveView patterns eliminate manual refresh

  **Advantages**:
  - Single source of truth for component behavior
  - No import/export JavaScript module management
  - Automatic compilation to `phoenix-colocated/heaters/` directory
  - Built-in namespacing prevents hook name collisions
  - Better maintainability with related code together

  ## Usage

      <.clip_player clip={@current_clip} temp_clip={@temp_clip} />

  The component automatically determines the appropriate video URL and player type
  based on the clip's properties and generates files as needed.

  ## Colocated Hook Implementation

  The JavaScript functionality is embedded using LiveView 1.1's ColocatedHook:

  ```elixir
  <script :type={ColocatedHook} name=".ClipPlayer">
    export default {
      mounted() { /* Hook lifecycle */ },
      updated() { /* React to LiveView updates */ },
      destroyed() { /* Cleanup */ }
    }
  </script>
  ```

  This replaces the previous separate JavaScript files while maintaining identical
  functionality with improved maintainability and automatic namespacing.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.ColocatedHook
  alias Heaters.Storage.S3.ClipUrlGenerator

  @doc """
  Renders a clip player component.

  ## Attributes

  - `clip` - The clip to play (required)
  - `temp_clip` - Temp clip state from LiveView reactive updates (optional)
  - `id` - HTML id for the video element (optional, defaults to "video-player")
  - `class` - Additional CSS classes (optional)
  - `controls` - Show video controls (optional, defaults to true)
  - `preload` - Video preload strategy (optional, defaults to "metadata")

  ## Reactive Pattern

  The `temp_clip` attribute enables Phoenix LiveView reactive updates:
  - LiveView stores temp clip state separately in assigns
  - When background jobs complete, PubSub updates trigger assign changes
  - Component automatically detects URL changes and updates player
  - JavaScript ClipPlayerController handles transitions via updated() lifecycle
  - No manual refresh or push_event calls required

  This eliminates the need for manual event listeners and provides a clean,
  idiomatic Phoenix LiveView reactive pattern for real-time video updates.
  """
  attr(:clip, :map, required: true)
  attr(:temp_clip, :map, default: %{})
  attr(:id, :string, default: nil)
  attr(:class, :string, default: "")
  attr(:controls, :boolean, default: true)
  attr(:preload, :string, default: "metadata")

  def clip_player(assigns) do
    # Get video URL and player type, passing temp clip info from LiveView assigns
    {video_url, player_type, clip_info} = get_video_data(assigns.clip, assigns.temp_clip)

    # Use a stable ID based on clip to prevent unnecessary DOM recreation
    video_id = assigns.id || "video-player-#{assigns.clip.id}"

    assigns =
      assigns
      |> assign(:video_url, video_url)
      |> assign(:player_type, player_type)
      |> assign(:clip_info, clip_info)
      |> assign(:video_id, video_id)
      |> assign(:clip_key, "clip-#{assigns.clip.id}")

    ~H"""
    <figure class="video-player-container" id={"video-container-#{@clip.id}"} role="img" aria-label={"Video clip player for clip #{@clip.id}"}>
      <%= cond do %>
        <% @video_url -> %>
          <video
            id={@video_id}
            class={["video-player", @class]}
            controls={@controls}
            muted
            preload={@preload}
            playsinline
            crossorigin="anonymous"
            phx-hook=".ClipPlayer"
            phx-update="ignore"
            data-video-url={@video_url}
            data-player-type={@player_type}
            data-clip-info={Jason.encode!(@clip_info)}
          >
            <p role="alert">Your browser doesn't support HTML5 video playback. Please update your browser or use a modern browser that supports HTML5 video.</p>
          </video>

          <section class="clip-player-loading" style="display: none;" role="status" aria-live="polite" aria-label="Video loading">
            <div class="spinner" role="progressbar" aria-label="Loading video"></div>
          </section>

        <% @player_type == "loading" -> %>
          <section class="video-player-loading" role="status" aria-live="polite" aria-label="Video generation">
            <div class="spinner" role="progressbar" aria-label="Generating video"></div>
          </section>

        <% true -> %>
          <section class="video-player-error" role="alert" aria-live="assertive" aria-label="Video playback error">
            <h3 class="error-title">Video not available for playback</h3>
            <p class="error-details">
              <%= if is_nil(@clip.clip_filepath) do %>
                Clip requires proxy file for temp playback generation.
              <% else %>
                Exported clip file not found.
              <% end %>
            </p>
          </section>
      <% end %>
    </figure>

    <script :type={ColocatedHook} name=".ClipPlayer">
      // Phoenix LiveView Colocated Hook for Clip Player
      // Integrates ClipPlayer functionality with Phoenix LiveView reactive patterns
      /** @type {import("phoenix_live_view").Hook} */

      export default {
        mounted() {
          const videoElement = this.el;
          const videoUrl = videoElement.dataset.videoUrl;
          const playerType = videoElement.dataset.playerType;
          const clipInfoJson = videoElement.dataset.clipInfo;

          // Parse clip information
          let clipInfo = {};
          try {
            if (clipInfoJson) {
              clipInfo = JSON.parse(clipInfoJson);
            }
          } catch (error) {
            console.error("[ClipPlayer] Failed to parse clip info:", error);
          }

          // Create the player instance with embedded class
          this.player = new ClipPlayerCore(videoElement, {
            controls: true,
            preload: 'metadata',
            showLoadingSpinner: true
          });

          // Load the video if URL is provided, otherwise show loading state
          if (videoUrl) {
            this.player.loadVideo(videoUrl, playerType, clipInfo).catch(error => {
              console.error("[ClipPlayer] Failed to load video:", error);
            });
          } else if (playerType === "loading" && clipInfo.is_loading) {
            // Show loading state for clips being generated
            this.player.showLoading();
          }

          // Store current state for comparison on updates
          this.currentVideoUrl = videoUrl;
          this.currentPlayerType = playerType;
          this.currentClipId = clipInfo.clip_id;
        },

        updated() {
          if (!this.player) {
            console.warn("[ClipPlayer] Player not initialized on update");
            return;
          }

          const videoElement = this.el;
          const videoUrl = videoElement.dataset.videoUrl;
          const playerType = videoElement.dataset.playerType;
          const clipInfoJson = videoElement.dataset.clipInfo;

          // Parse updated clip information
          let clipInfo = {};
          try {
            if (clipInfoJson) {
              clipInfo = JSON.parse(clipInfoJson);
            }
          } catch (error) {
            console.error("[ClipPlayer] Failed to parse updated clip info:", error);
          }

          // Reactive Pattern: Detect state transitions from LiveView assign updates
          const wasLoading = this.currentPlayerType === "loading" || !this.currentVideoUrl;
          const nowReady = videoUrl && playerType && playerType !== "loading";
          const urlChanged = videoUrl && videoUrl !== this.currentVideoUrl;
          const typeChanged = playerType && playerType !== this.currentPlayerType;

          if ((wasLoading && nowReady) || urlChanged || typeChanged) {
            this.currentVideoUrl = videoUrl;
            this.currentPlayerType = playerType;

            // Use switchClip for smooth transitions between clips
            this.player.switchClip(videoUrl, playerType, clipInfo).catch(error => {
              console.error("[ClipPlayer] Failed to switch to new clip:", error);
            });
          }
        },

        destroyed() {
          if (this.player) {
            this.player.destroy();
            this.player = null;
          }

          this.currentVideoUrl = null;
          this.currentPlayerType = null;
          this.currentClipId = null;
        }
      }

      // ClipPlayer core functionality - embedded in colocated hook
      class ClipPlayerCore {
        constructor(videoElement, options = {}) {
          this.video = videoElement;
          this.options = {
            preload: 'metadata',
            controls: true,
            showLoadingSpinner: true,
            ...options
          };

          this.playerType = null;
          this.isLoading = false;
          this.isLoadingNewVideo = false;
          this.loadingSpinner = null;
          this.frameNavigationMode = false; // Add frame navigation mode flag

          this.init();
        }

        init() {
          this.setupLoadingSpinner();
          this.setupFrameNavigationEvents();

          // Store bound handlers so we can remove them later
          this.boundHandlers = {
            loadstart: this.handleLoadStart.bind(this),
            loadedmetadata: this.handleLoadedMetadata.bind(this),
            canplay: this.handleCanPlay.bind(this),
            canplaythrough: this.handleCanPlayThrough.bind(this),
            waiting: this.handleWaiting.bind(this),
            error: this.handleError.bind(this),
            ended: this.handleEnded.bind(this)
          };

          // Add event listeners for clip playback behavior
          this.video.addEventListener('loadstart', this.boundHandlers.loadstart);
          this.video.addEventListener('loadedmetadata', this.boundHandlers.loadedmetadata);
          this.video.addEventListener('canplay', this.boundHandlers.canplay);
          this.video.addEventListener('canplaythrough', this.boundHandlers.canplaythrough);
          this.video.addEventListener('waiting', this.boundHandlers.waiting);
          this.video.addEventListener('error', this.boundHandlers.error);
          this.video.addEventListener('ended', this.boundHandlers.ended);

          console.log('[ClipPlayer] Initialized with colocated hooks');
        }

        setupLoadingSpinner() {
          if (!this.options.showLoadingSpinner) return;

          const container = this.video.parentElement;
          this.loadingSpinner = container?.querySelector('.clip-player-loading');

          if (!this.loadingSpinner) {
            console.warn('[ClipPlayer] Loading spinner not found in template');
          }
        }

        setupFrameNavigationEvents() {
          // Listen for frame navigation events from other hooks
          this.handleFrameNavigationRequest = (event) => {
            console.log('[ClipPlayer] Received frame-navigation-request event:', event.detail);
            const { direction, frameStep } = event.detail;
            this.navigateFrames(direction, frameStep);
          };

          this.handleFrameNavigationToggle = (event) => {
            console.log('[ClipPlayer] Received frame-navigation-toggle event:', event.detail);
            const { enabled } = event.detail;
            if (enabled) {
              this.enableFrameNavigationMode();
            } else {
              this.disableFrameNavigationMode();
            }
          };

          this.video.addEventListener('frame-navigation-request', this.handleFrameNavigationRequest);
          this.video.addEventListener('frame-navigation-toggle', this.handleFrameNavigationToggle);
          
          console.log('[ClipPlayer] Frame navigation events registered on video element:', this.video);
        }

        async loadVideo(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
          if (!videoUrl) {
            console.error('[ClipPlayer] No video URL provided');
            return;
          }

          console.log(`[ClipPlayer] Loading ${playerType} video: ${videoUrl}`);

          try {
            this.video.pause();
            this.video.removeAttribute('src');
            this.video.load();
          } catch (_) { }

          this.playerType = playerType;
          this.clipInfo = clipInfo;

          if (playerType === 'ffmpeg_stream') {
            this.showLoading();
          }

          this.video.src = videoUrl;

          if (clipInfo) {
            console.log(`[ClipPlayer] Clip info:`, clipInfo);
          }
        }

        async switchClip(videoUrl, playerType = 'ffmpeg_stream', clipInfo = null) {
          console.log(`[ClipPlayer] Switching to new clip: ${videoUrl}`);
          this.video.pause();
          
          // Show loading immediately for better UX
          if (playerType === 'ffmpeg_stream') {
            this.showLoading();
          }
          
          await this.loadVideo(videoUrl, playerType, clipInfo);
        }

        handleLoadStart() {
          console.log('[ClipPlayer] Load started');
          if (this.playerType === 'ffmpeg_stream') {
            this.showLoading();
          }
        }

        handleLoadedMetadata() {
          console.log('[ClipPlayer] Metadata loaded - clip ready');
          
          if (this.playerType === 'direct_s3' && this.video.currentTime > 0.01 &&
              this.video.dataset.clipOffsetReset !== '1') {
            console.log('[ClipPlayer] Resetting video time to 0 for direct_s3 player');
            this.video.currentTime = 0;
            this.video.dataset.clipOffsetReset = '1';
          }
        }

        handleCanPlay() {
          console.log('[ClipPlayer] Can play - video is ready but may still buffer');
        }

        handleCanPlayThrough() {
          console.log('[ClipPlayer] Can play through - hiding loading spinner and starting autoplay');
          this.hideLoading();
          this.attemptAutoplay();
        }

        async attemptAutoplay() {
          try {
            console.log('[ClipPlayer] Attempting autoplay...');
            await this.video.play();
            console.log('[ClipPlayer] Autoplay succeeded');
          } catch (error) {
            console.log('[ClipPlayer] Autoplay failed:', error);

            setTimeout(async () => {
              try {
                console.log('[ClipPlayer] Retrying autoplay after delay...');
                await this.video.play();
                console.log('[ClipPlayer] Delayed autoplay succeeded');
              } catch (retryError) {
                console.log('[ClipPlayer] Autoplay blocked by browser policy');
              }
            }, 100);
          }
        }

        handleWaiting() {
          console.log('[ClipPlayer] Waiting for data');
          if (this.playerType === 'ffmpeg_stream') {
            this.showLoading();
          }
        }

        handleError(event) {
          if (this.video.error && this.video.error.code === 4 &&
              (this.video.error.message.includes('Empty src attribute') ||
               this.video.error.message.includes('MEDIA_ELEMENT_ERROR: Empty src attribute'))) {
            console.log('[ClipPlayer] Ignoring empty src error during video transition');
            return;
          }

          if (this.isLoadingNewVideo) {
            console.log('[ClipPlayer] Ignoring error during new video load');
            return;
          }

          console.error('[ClipPlayer] Video error:', event);
          console.error('[ClipPlayer] Video error details:', {
            error: this.video.error,
            networkState: this.video.networkState,
            readyState: this.video.readyState,
            currentSrc: this.video.currentSrc
          });

          this.hideLoading();

          this.video.dispatchEvent(new CustomEvent('cliperror', {
            detail: {
              error: event,
              playerType: this.playerType
            }
          }));
        }

        handleEnded() {
          console.log('[ClipPlayer] Clip ended - looping back to start');
          
          // Always loop clips back to the beginning
          this.video.currentTime = 0;
          this.video.play().catch(error => {
            console.log('[ClipPlayer] Loop playback failed:', error);
          });

          this.video.dispatchEvent(new CustomEvent('clipended', {
            detail: {
              playerType: this.playerType,
              currentTime: this.video.currentTime,
              duration: this.video.duration,
              looped: true
            }
          }));
        }

        showLoading() {
          if (!this.loadingSpinner) return;
          this.isLoading = true;
          this.loadingSpinner.style.display = 'block';
        }

        hideLoading() {
          if (!this.loadingSpinner) return;
          this.isLoading = false;
          this.loadingSpinner.style.display = 'none';
        }

        async play() {
          try {
            await this.video.play();
          } catch (error) {
            console.error('[ClipPlayer] Play error:', error);
            throw error;
          }
        }

        pause() {
          this.video.pause();
        }

        seekTo(timeSeconds) {
          this.video.currentTime = Math.max(0, Math.min(this.video.duration || 0, timeSeconds));
        }

        // Enable frame navigation mode - completely disables automatic behaviors
        enableFrameNavigationMode() {
          if (this.frameNavigationMode) return; // Already enabled
          
          console.log('[ClipPlayer] Entering frame navigation mode - disabling automatic behaviors');
          this.frameNavigationMode = true;
          
          // Pause and save current state
          this.video.pause();
          this.savedCurrentTime = this.video.currentTime;
          
          // Disable automatic behaviors by removing event listeners temporarily
          this.disableAutomaticBehaviors();
        }

        // Disable frame navigation mode - re-enables automatic behaviors  
        disableFrameNavigationMode() {
          if (!this.frameNavigationMode) return; // Already disabled
          
          console.log('[ClipPlayer] Exiting frame navigation mode - re-enabling automatic behaviors');
          this.frameNavigationMode = false;
          
          // Re-enable automatic behaviors
          this.enableAutomaticBehaviors();
          
          // Resume normal playback
          this.attemptAutoplay();
        }

        // Temporarily disable event handlers that interfere with frame navigation
        disableAutomaticBehaviors() {
          // Remove interfering handlers using the stored bound references
          this.video.removeEventListener('loadedmetadata', this.boundHandlers.loadedmetadata);
          this.video.removeEventListener('canplay', this.boundHandlers.canplay);
          this.video.removeEventListener('canplaythrough', this.boundHandlers.canplaythrough); 
          this.video.removeEventListener('ended', this.boundHandlers.ended);
          
          console.log('[ClipPlayer] Automatic behaviors disabled');
        }

        // Re-enable automatic behaviors
        enableAutomaticBehaviors() {
          // Restore event handlers using the stored bound references
          this.video.addEventListener('loadedmetadata', this.boundHandlers.loadedmetadata);
          this.video.addEventListener('canplay', this.boundHandlers.canplay);
          this.video.addEventListener('canplaythrough', this.boundHandlers.canplaythrough);
          this.video.addEventListener('ended', this.boundHandlers.ended);
          
          console.log('[ClipPlayer] Automatic behaviors re-enabled');
        }

        // Frame-accurate seeking for navigation
        seekToFrame(timeSeconds) {
          this.enableFrameNavigationMode();
          
          // Pause video to prevent interference
          this.video.pause();
          
          // Set time directly
          this.video.currentTime = Math.max(0, Math.min(this.video.duration || 0, timeSeconds));
          
          // Use seeking event to confirm the seek completed
          const onSeeked = () => {
            this.video.removeEventListener('seeked', onSeeked);
            console.log('[ClipPlayer] Frame seek completed to:', this.video.currentTime);
            
            // Keep frame navigation mode active until explicitly disabled
          };
          
          this.video.addEventListener('seeked', onSeeked, { once: true });
          
          return this.video.currentTime;
        }

        // Navigate frames in the specified direction
        navigateFrames(direction, frameStep = 3) {
          console.log(`[ClipPlayer] navigateFrames called: direction=${direction}, frameStep=${frameStep}`);
          
          // Ensure frame navigation mode is enabled
          this.enableFrameNavigationMode();
          
          // Calculate frame step (default 3 frames = 0.1 seconds at 30fps for visible navigation)
          const frameStepSeconds = frameStep / 30;
          const currentTime = this.video.currentTime;
          const newTime = direction === 'left' || direction === 'backward'
            ? Math.max(0, currentTime - frameStepSeconds)
            : Math.min(this.video.duration || 0, currentTime + frameStepSeconds);
          
          console.log(`[ClipPlayer] Frame navigation (${frameStep} frames) from ${currentTime.toFixed(3)}s to ${newTime.toFixed(3)}s (${direction})`);
          
          // Direct time setting - no interference since event handlers are disabled
          this.video.currentTime = newTime;
          
          // Immediate verification
          const actualTime = this.video.currentTime;
          console.log(`[ClipPlayer] Frame navigation result: ${actualTime.toFixed(3)}s (target: ${newTime.toFixed(3)}s)`);
          
          return actualTime;
        }

        getCurrentTime() {
          return this.video.currentTime;
        }

        getDuration() {
          return this.video.duration || 0;
        }

        loop() {
          this.video.loop = true;
        }

        unloop() {
          this.video.loop = false;
        }

        isLoadingState() {
          return this.isLoading;
        }

        getPlayerType() {
          return this.playerType;
        }

        destroy() {
          console.log('[ClipPlayer] Destroying player...');

          try {
            if (!this.video.paused) {
              this.video.pause();
            }
          } catch (error) {
            // Ignore errors during destruction
          }

          // If in frame navigation mode, restore event handlers before cleanup
          if (this.frameNavigationMode) {
            this.enableAutomaticBehaviors();
          }

          // Remove event listeners using bound handlers
          if (this.boundHandlers) {
            this.video.removeEventListener('loadstart', this.boundHandlers.loadstart);
            this.video.removeEventListener('loadedmetadata', this.boundHandlers.loadedmetadata);
            this.video.removeEventListener('canplay', this.boundHandlers.canplay);
            this.video.removeEventListener('canplaythrough', this.boundHandlers.canplaythrough);
            this.video.removeEventListener('waiting', this.boundHandlers.waiting);
            this.video.removeEventListener('error', this.boundHandlers.error);
            this.video.removeEventListener('ended', this.boundHandlers.ended);
          }

          // Remove frame navigation event listeners
          this.video.removeEventListener('frame-navigation-request', this.handleFrameNavigationRequest);
          this.video.removeEventListener('frame-navigation-toggle', this.handleFrameNavigationToggle);

          if (this.loadingSpinner) {
            this.hideLoading();
            this.loadingSpinner = null;
          }

          this.isLoadingNewVideo = false;
          this.isLoading = false;

          this.video.src = '';
          this.video.load();

          console.log('[ClipPlayer] Destroyed');
        }
      }
    </script>
    """
  end

  # Helper function to get video data for the component
  defp get_video_data(clip, temp_clip \\ %{}) do
    # Load source video if not already loaded
    source_video =
      case clip do
        %{source_video: %{} = sv} ->
          sv

        %{source_video_id: id} when not is_nil(id) ->
          # In a real app, you'd load this from the database
          # For now, assume it's preloaded or handle the error case
          %{proxy_filepath: nil}

        _ ->
          %{proxy_filepath: nil}
      end

    # Check if temp clip is ready (reactive update from LiveView assigns)
    case temp_clip do
      %{clip_id: clip_id, url: url, ready: true} when clip_id == clip.id and not is_nil(url) ->
        clip_info = build_clip_info(clip, :direct_s3)
        {url, "direct_s3", clip_info}

      _ ->
        # Fall back to normal video URL generation
        case ClipUrlGenerator.get_video_url(clip, source_video) do
          {:ok, url, player_type} ->
            clip_info = build_clip_info(clip, player_type)
            {url, to_string(player_type), clip_info}

          {:loading, nil} ->
            # Return a placeholder data structure for loading state
            clip_info = build_clip_info(clip, :loading)
            {nil, "loading", clip_info}

          {:error, _reason} ->
            {nil, "error", %{}}
        end
    end
  end

  # Build clip information for the JavaScript player
  # Each clip is treated as a standalone file
  defp build_clip_info(%{clip_filepath: nil} = clip, :loading) do
    %{
      has_exported_file: false,
      is_loading: true,
      clip_id: clip.id,
      start_frame: clip.start_frame,
      end_frame: clip.end_frame,
      start_time_seconds: clip.start_time_seconds,
      end_time_seconds: clip.end_time_seconds,
      duration_seconds: clip.end_time_seconds - clip.start_time_seconds
    }
  end

  defp build_clip_info(%{clip_filepath: nil} = clip, _player_type) do
    %{
      has_exported_file: false,
      is_loading: false,
      clip_id: clip.id,
      start_frame: clip.start_frame,
      end_frame: clip.end_frame,
      start_time_seconds: clip.start_time_seconds,
      end_time_seconds: clip.end_time_seconds,
      duration_seconds: clip.end_time_seconds - clip.start_time_seconds
    }
  end

  defp build_clip_info(%{clip_filepath: _filepath} = clip, _player_type) do
    %{
      has_exported_file: true,
      is_loading: false,
      clip_id: clip.id,
      start_frame: clip.start_frame,
      end_frame: clip.end_frame
    }
  end

  @doc """
  Helper function to get clip video URL for preloading.

  Used in templates for preloading next clips or sequential playback.
  """
  def clip_video_url(clip) when is_map(clip) do
    {url, _player_type, _clip_info} = get_video_data(clip)
    url
  end

  def clip_video_url(_), do: nil
end
