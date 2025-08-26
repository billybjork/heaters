defmodule HeatersWeb.ClipPlayer do
  @moduledoc """
  Phoenix LiveView component for clip playback with frame-accurate navigation.

  This component provides video clip playback with precise frame stepping capabilities
  for the review interface. It integrates with JavaScript hooks for advanced video
  control and split-mode frame navigation.

  ## Key Features

  - **Instant Playback**: Small files (2-5MB) generated on-demand using FFmpeg stream copy
  - **Perfect Timeline**: Shows exact clip duration, not full video length
  - **Zero Re-encoding**: Stream copy ensures fastest generation with zero quality loss
  - **Frame Navigation**: Precise frame-by-frame stepping using database FPS data
  - **Split Mode**: Advanced editing with frame-accurate cut point selection
  - **Universal Compatibility**: Works offline, all browsers, mobile optimized
  - **Reactive Updates**: Phoenix LiveView patterns eliminate manual refresh

  ## Usage

      <.clip_player clip={@current_clip} />

  The component automatically determines the appropriate video URL and player type
  based on the clip's properties using virtual subclips when needed.

  ## JavaScript Hook Integration

  The component uses the `ClipPlayer` JavaScript hook (defined in `assets/js/clip-player.js`)
  for advanced video control including:

  - Frame-by-frame navigation in split mode
  - Precise seeking with browser compatibility layers
  - Video loading state management
  - Split mode entry/exit coordination with ReviewHotkeys

  The hook receives clip metadata including FPS data from the database for
  accurate frame calculations.
  """

  use Phoenix.Component
  alias Heaters.Storage.S3.ClipUrls
  require Logger

  @doc """
  Renders a clip player component.

  ## Attributes

  - `clip` - The clip to play (required)
  - `id` - HTML id for the video element (optional, defaults to "video-player")
  - `class` - Additional CSS classes (optional)
  - `controls` - Show video controls (optional, defaults to true)
  - `preload` - Video preload strategy (optional, defaults to "metadata")

  ## Virtual Clip Integration

  The component automatically uses virtual clips for instant playback:
  - Direct HTTP Range requests to CloudFront for clip segments
  - No temp file generation or background processing needed
  - Frame-accurate navigation using database FPS data
  - JavaScript ClipPlayer hook handles video control and split mode integration
  """
  attr(:clip, :map, required: true)
  attr(:id, :string, default: nil)
  attr(:class, :string, default: "")
  attr(:controls, :boolean, default: true)
  attr(:preload, :string, default: "metadata")

  def clip_player(assigns) do
    # Get video URL and player type for the clip
    {video_url, player_type, clip_info} = get_video_data(assigns.clip)

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
            data-virtual-clip={@player_type == "virtual_clip"}
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
    """
  end

  # Helper function to get video data for the component
  defp get_video_data(clip) do
    # Load source video if not already loaded
    source_video =
      case Map.get(clip, :source_video) do
        %{} = sv ->
          sv

        _ ->
          # Fallback source video structure
          %{
            proxy_filepath: nil,
            fps: 30.0
          }
      end

    # Use the best available clip URL (exported or virtual)
    case ClipUrls.get_clip_url(clip, source_video) do
      {:ok, url, player_type} ->
        clip_info = build_clip_info(clip, player_type)
        {url, Atom.to_string(player_type), clip_info}

      {:error, reason} ->
        Logger.error("ClipUrls failed: #{reason}")
        {nil, "error", %{}}
    end
  end

  # Build clip information for the JavaScript player
  defp build_clip_info(clip, player_type) do
    # Get fps from source video for precise frame navigation
    fps = get_source_video_fps(clip)

    # Build clip info based on the determined player type
    %{
      has_exported_file: player_type == :direct_s3,
      is_loading: false,
      clip_id: clip.id,
      start_frame: clip.start_frame,
      end_frame: clip.end_frame,
      start_time_seconds: clip.start_time_seconds,
      end_time_seconds: clip.end_time_seconds,
      duration_seconds: clip.end_time_seconds - clip.start_time_seconds,
      fps: fps,
      player_type: player_type
    }
  end

  # Helper to extract FPS from source video, with fallback
  defp get_source_video_fps(clip) do
    case Map.get(clip, :source_video) do
      %{fps: fps} when is_number(fps) and fps > 0 -> fps
      # Fallback FPS if not available
      _ -> 30.0
    end
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
