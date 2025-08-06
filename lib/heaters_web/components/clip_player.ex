defmodule HeatersWeb.ClipPlayer do
  @moduledoc """
  Phoenix LiveView component for clip playback in different lifecycle stages.

  Provides a simple HTML5 video element that plays clips, with temp clips
  generating small MP4 files on-demand using FFmpeg stream copy.

  Key features:
  - Temp clips: Small files (2-5MB) generated on-demand using FFmpeg stream copy (no re-encoding)
  - Instant playback with correct timeline duration (clips show their actual length)
  - Native HTML5 video element (no complex streaming protocols)
  - CloudFront caching for global distribution
  - Support for both temp clips (on-demand generated) and exported clips (direct files)
  - Superior user experience compared to byte-range streaming

  ## Usage

      <.clip_player clip={@current_clip} />

  The component automatically determines the appropriate video URL and player type
  based on the clip's properties and generates files as needed.
  """

  use Phoenix.Component
  alias HeatersWeb.VideoUrlHelper

  @doc """
  Renders a clip player component.

  ## Attributes

  - `clip` - The clip to play (required)
  - `id` - HTML id for the video element (optional, defaults to "video-player")
  - `class` - Additional CSS classes (optional)
  - `controls` - Show video controls (optional, defaults to true)
  - `preload` - Video preload strategy (optional, defaults to "metadata")
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
    <div class="video-player-container" id={"video-container-#{@clip.id}"}>
      <%= cond do %>
        <% @video_url -> %>
          <video
            id={@video_id}
            class={["video-player", @class]}
            controls={@controls}
            muted
            preload="none"
            playsinline
            crossorigin="anonymous"
            phx-hook="ClipPlayer"
            phx-update="ignore"
            data-video-url={@video_url}
            data-player-type={@player_type}
            data-clip-info={Jason.encode!(@clip_info)}
          >
            <p>Your browser doesn't support HTML5 video playback.</p>
          </video>

          <div class="clip-player-loading" style="display: none;">
            <div class="spinner"></div>
            <div class="loading-text">Loading clip...</div>
          </div>

        <% @player_type == "loading" -> %>
          <div class="video-player-loading">
            <div class="spinner"></div>
            <div class="loading-text">Generating temp clip...</div>
          </div>

        <% true -> %>
          <div class="video-player-error">
              <p>Video not available for playback.</p>
              <p class="error-details">
                <%= if is_nil(@clip.clip_filepath) do %>
                  Clip requires proxy file for temp playback generation.
                <% else %>
                  Exported clip file not found.
                <% end %>
              </p>
          </div>
      <% end %>
    </div>
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
        case VideoUrlHelper.get_video_url(clip, source_video) do
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
      start_time_seconds: clip.start_time_seconds,
      end_time_seconds: clip.end_time_seconds,
      duration_seconds: clip.end_time_seconds - clip.start_time_seconds
    }
  end

  defp build_clip_info(%{clip_filepath: _filepath} = clip, _player_type) do
    %{
      has_exported_file: true,
      is_loading: false,
      clip_id: clip.id
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
