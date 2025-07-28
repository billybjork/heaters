defmodule HeatersWeb.CloudFrontVideoPlayer do
  @moduledoc """
  Phoenix LiveView component for CloudFront video streaming.

  Provides a simple HTML5 video element that leverages CloudFront's native
  byte-range support for efficient video streaming and seeking.

  Key features:
  - Native HTML5 video element (no complex decoders)
  - CloudFront byte-range requests for efficient seeking
  - Support for both virtual clips (with timing constraints) and physical clips
  - Simple, maintainable implementation

  ## Usage

      <.cloudfront_video_player clip={@current_clip} />

  The component automatically determines the appropriate video URL and player type
  based on the clip's properties and the source video's available files.
  """

  use Phoenix.Component
  alias HeatersWeb.VideoUrlHelper

  @doc """
  Renders a CloudFront video player component.

  ## Attributes

  - `clip` - The clip to play (required)
  - `id` - HTML id for the video element (optional, defaults to "video-player")
  - `class` - Additional CSS classes (optional)
  - `controls` - Show video controls (optional, defaults to true)
  - `preload` - Video preload strategy (optional, defaults to "metadata")
  """
  attr(:clip, :map, required: true)
  attr(:id, :string, default: "video-player")
  attr(:class, :string, default: "")
  attr(:controls, :boolean, default: true)
  attr(:preload, :string, default: "none")

  def cloudfront_video_player(assigns) do
    # Get video URL and player type
    {video_url, player_type, clip_info} = get_video_data(assigns.clip)

    assigns =
      assigns
      |> assign(:video_url, video_url)
      |> assign(:player_type, player_type)
      |> assign(:clip_info, clip_info)
      |> assign(:clip_key, "clip-#{assigns.clip.id}")

    ~H"""
    <div class="video-player-container">
      <%= if @video_url do %>
        <video
          id={@id}
          class={["video-player", @class]}
          controls={@controls}
          preload="none"
          crossorigin="anonymous"
          phx-hook="CloudFrontVideoPlayer"
          data-video-url={@video_url}
          data-player-type={@player_type}
          data-clip-info={Jason.encode!(@clip_info)}
          poster="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='800' height='600'%3E%3Crect width='100%25' height='100%25' fill='%23f0f0f0'/%3E%3Ctext x='50%25' y='50%25' font-family='Arial' font-size='24' fill='%23666' text-anchor='middle' dy='.3em'%3EClick to load video%3C/text%3E%3C/svg%3E"
        >
          <p>Your browser doesn't support HTML5 video streaming.</p>
        </video>
      <% else %>
        <div class="video-player-error">
          <p>Video not available for streaming.</p>
          <p class="error-details">
            <%= if @clip.is_virtual do %>
              Virtual clip requires proxy file for streaming.
            <% else %>
              Physical clip file not found.
            <% end %>
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper function to get video data for the component
  defp get_video_data(clip) do
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

    case VideoUrlHelper.get_video_url(clip, source_video) do
      {:ok, url, player_type} ->
        clip_info = build_clip_info(clip, player_type)
        {url, to_string(player_type), clip_info}

      {:error, _reason} ->
        {nil, "error", %{}}
    end
  end

  # Build clip timing information for the JavaScript player
  defp build_clip_info(%{is_virtual: true} = clip, _player_type) do
    %{
      is_virtual: true,
      start_time_seconds: clip.start_time_seconds,
      end_time_seconds: clip.end_time_seconds,
      duration_seconds: clip.end_time_seconds - clip.start_time_seconds
    }
  end

  defp build_clip_info(%{is_virtual: false}, _player_type) do
    %{
      is_virtual: false
    }
  end

  @doc """
  Helper function to get proxy video URL for preloading.

  Used in templates for preloading next clips.
  """
  def proxy_video_url(clip) when is_map(clip) do
    {url, _player_type, _clip_info} = get_video_data(clip)
    url
  end

  def proxy_video_url(_), do: nil
end
