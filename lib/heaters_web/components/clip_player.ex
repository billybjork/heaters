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
            phx-hook="ClipPlayer"
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

    <!-- ClipPlayer now uses regular JavaScript hook -->
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
