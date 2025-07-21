defmodule HeatersWeb.WebCodecsPlayer do
  @moduledoc """
  WebCodecs-based video player for virtual clips.

  This component replaces sprite-based navigation with direct video seeking
  using keyframe offsets for frame-perfect navigation on review proxy videos.
  Automatically falls back to traditional <video> player when WebCodecs is unavailable.
  """
  use Phoenix.Component
  alias Heaters.Clips.Clip

  # ------------------------------------------------------------------------
  # public helpers
  # ------------------------------------------------------------------------

  @doc """
  Return the CDN review proxy URL for a virtual clip's source video.

  Used for WebCodecs frame seeking and fallback video playback.
  """
  @spec proxy_video_url(Clip.t()) :: String.t() | nil
  def proxy_video_url(%Clip{source_video: source_video}) when not is_nil(source_video) do
    case source_video.proxy_filepath do
      nil -> nil
      proxy_path -> cdn_url(proxy_path)
    end
  end
  def proxy_video_url(_clip), do: nil

  @doc """
  Return the CDN clip URL for physical clips (fallback).
  """
  @spec clip_video_url(Clip.t()) :: String.t() | nil
  def clip_video_url(%Clip{clip_filepath: nil}), do: nil
  def clip_video_url(%Clip{clip_filepath: clip_path}), do: cdn_url(clip_path)

  # ------------------------------------------------------------------------
  # live-component pieces
  # ------------------------------------------------------------------------

  @doc "Renders the WebCodecs video player for one clip."
  def webcodecs_player(assigns) do
    clip = assigns.clip
    meta = build_webcodecs_player_meta(clip)
    json_meta = Jason.encode!(meta)

    assigns =
      assigns
      |> assign(:meta, meta)
      |> assign(:json_meta, json_meta)

    ~H"""
    <div class="clip-display-container" style={"width: #{@meta["display_width"]}px;"}>
      <div
        id={"viewer-#{@clip.id}"}
        phx-hook="WebCodecsPlayer"
        phx-update="ignore"
        data-clip-id={@clip.id}
        data-player={@json_meta}
        class="webcodecs-viewer"
        style={"width: #{@meta["display_width"]}px;
                height: #{@meta["display_height"]}px;
                background-color: #000;
                border-radius: 4px;
                overflow: hidden;"}
      >
        <!-- WebCodecs canvas or video element will be inserted here -->
      </div>

      <div class="webcodecs-controls">
        <button
          id={"playpause-#{@clip.id}"}
          class="review-buttons__action review-buttons__action--play"
          data-action="toggle"
        >
          ▶
        </button>

        <input id={"scrub-#{@clip.id}"} type="range" min="0" step="1" />

        <button
          id={"speed-#{@clip.id}"}
          class="review-buttons__action review-buttons__action--speed"
          disabled
        >
          1×
        </button>

        <span id={"frame-display-#{@clip.id}"}>
          Frame: 0
        </span>

        <span class="webcodecs-indicator" style="font-size: 12px; color: #666; margin-left: auto;">
          <%= if @meta["is_virtual"] do %>
            <span style="color: #0066cc;">⚡ Virtual</span>
          <% else %>
            <span style="color: #666;">📹 Traditional</span>
          <% end %>
        </span>
      </div>
    </div>
    """
  end

  @doc """
  Lightweight meta map for thumbnails (WebCodecs-compatible).
  Returns JSON for hover-autoplay functionality.
  """
  def thumb_meta_json(%Clip{} = clip) do
    build_webcodecs_player_meta(clip)
    |> Map.take([
      "display_width",
      "display_height",
      "total_frames",
      "fps",
      "proxy_video_url",
      "is_virtual"
    ])
    |> Jason.encode!()
  end

  # ------------------------------------------------------------------------
  # private helpers
  # ------------------------------------------------------------------------

  defp build_webcodecs_player_meta(clip) do
    source_video = clip.source_video || %{}

    # Determine if this is a virtual clip
    is_virtual = clip.is_virtual || false

    # Calculate frame information
    fps = source_video.fps || clip.fps || 30.0

    {total_frames, duration_seconds} = calculate_frame_info(clip, fps)

    # Display dimensions (consistent with sprite player)
    display_width = 640  # Standard player width
    display_height = round(display_width * 9 / 16)  # 16:9 aspect ratio

    # Get video URLs
    proxy_url = if is_virtual, do: proxy_video_url(clip), else: nil
    clip_url = if not is_virtual, do: clip_video_url(clip), else: nil

    # Get keyframe offsets for virtual clips
    keyframe_offsets = if is_virtual do
      source_video.keyframe_offsets || []
    else
      []
    end

    %{
      # Core player information
      "is_virtual" => is_virtual,
      "total_frames" => total_frames,
      "fps" => fps,
      "duration_seconds" => duration_seconds,

      # Display settings
      "display_width" => display_width,
      "display_height" => display_height,

      # Video sources
      "proxy_video_url" => proxy_url,
      "clip_video_url" => clip_url,

      # WebCodecs-specific data
      "keyframe_offsets" => keyframe_offsets,

      # Cut points for virtual clips
      "cut_points" => if(is_virtual, do: clip.cut_points, else: nil),

      # Validation
      "is_valid" => has_valid_video_source?(is_virtual, proxy_url, clip_url),

      # Frame range (for compatibility with split manager)
      "start_frame" => clip.start_frame,
      "end_frame" => clip.end_frame
    }
  end

  defp calculate_frame_info(clip, fps) do
    cond do
      # Virtual clip with cut points
      clip.is_virtual && clip.cut_points ->
        start_time = clip.cut_points["start_time_seconds"] || 0.0
        end_time = clip.cut_points["end_time_seconds"] || 0.0
        duration = end_time - start_time
        frames = round(duration * fps)
        {max(frames, 1), duration}

      # Physical clip with time information
      clip.start_time_seconds && clip.end_time_seconds ->
        duration = clip.end_time_seconds - clip.start_time_seconds
        frames = round(duration * fps)
        {max(frames, 1), duration}

      # Fallback: Use source video duration if available
      clip.source_video && clip.source_video.duration_seconds ->
        duration = clip.source_video.duration_seconds
        frames = round(duration * fps)
        {max(frames, 1), duration}

      # Default fallback
      true ->
        {30, 1.0}  # 1 second at 30fps
    end
  end

  defp has_valid_video_source?(true, proxy_url, _clip_url) do
    # Virtual clips need proxy URL
    not is_nil(proxy_url)
  end

  defp has_valid_video_source?(false, _proxy_url, clip_url) do
    # Physical clips need clip URL
    not is_nil(clip_url)
  end

  defp cdn_url(nil), do: nil

  defp cdn_url(key) do
    # Use S3Adapter for consistent CDN URL generation with range request support
    Heaters.Infrastructure.Adapters.S3Adapter.proxy_cdn_url(key)
  end
end
