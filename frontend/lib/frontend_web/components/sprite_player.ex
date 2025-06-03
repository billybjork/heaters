defmodule FrontendWeb.SpritePlayer do
  @moduledoc false
  use Phoenix.Component
  alias Frontend.Clips.Clip

  # ------------------------------------------------------------------------
  # public helpers
  # ------------------------------------------------------------------------

  @doc """
  Return the CDN sprite-sheet URL for a clip (or a local placeholder).

  Used by the `<link rel="preload">` tag in *review_live.html.heex* and by
  any place that needs the sprite image outside the main player.
  """
  @spec sprite_url(Clip.t()) :: String.t()
  def sprite_url(%Clip{clip_artifacts: arts}) do
    case Enum.find(arts, &(&1.artifact_type == "sprite_sheet")) do
      nil -> "/images/placeholder_sprite.png"
      art -> cdn_url(art.s3_key)
    end
  end

  # ------------------------------------------------------------------------
  # live-component pieces
  # ------------------------------------------------------------------------

  @doc "Renders the sprite-sheet player for one clip."
  def sprite_player(assigns) do
    clip = assigns.clip
    sprite_art = Enum.find(clip.clip_artifacts, &(&1.artifact_type == "sprite_sheet"))
    meta = build_sprite_player_meta(clip, sprite_art)
    json_meta = Jason.encode!(meta)

    assigns =
      assigns
      |> assign(:meta, meta)
      |> assign(:json_meta, json_meta)

    ~H"""
    <div class="clip-display-container" style={"width: #{@meta["tile_width"]}px;"}>
      <div
        id={"viewer-#{@clip.id}"}
        phx-hook="SpritePlayer"
        phx-update="ignore"
        data-clip-id={@clip.id}
        data-player={@json_meta}
        class="sprite-viewer"
        style={"width: #{@meta["tile_width"]}px;
                height: #{@meta["tile_height_calculated"]}px;
                background-repeat: no-repeat;
                overflow: hidden;"}
      >
      </div>

      <div class="sprite-controls">
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
      </div>
    </div>
    """
  end

  @doc """
  Lightweight meta map for thumbnails (same fields the big player needs but
  only what hover-autoplay uses). Returns JSON.
  """
  def thumb_meta_json(%Clip{} = clip) do
    with art when not is_nil(art) <-
           Enum.find(clip.clip_artifacts, &(&1.artifact_type == "sprite_sheet")) do
      build_sprite_player_meta(clip, art)
      |> Map.take([
        "cols",
        "rows",
        "tile_width",
        "tile_height_calculated",
        "total_sprite_frames",
        "clip_fps",
        "spriteUrl"
      ])

      # ← string keys
      |> Jason.encode!()
    end
  end

  # ------------------------------------------------------------------------
  # private helpers
  # ------------------------------------------------------------------------

  defp build_sprite_player_meta(clip, art) do
    base = art.metadata || %{}

    cols = base["cols"] || 5
    tile_w = base["tile_width"] || 160
    tile_h = base["tile_height_calculated"] || round(tile_w * 9 / 16)

    fps =
      base["clip_fps"] ||
        base["clip_fps_source"] ||
        clip.source_video.fps ||
        24

    #  1.  real tile count (already stored by sprite.py)
    total_sprite_frames =
      base["total_sprite_frames"] || cols * (base["rows"] || 1)

    # 2.  logical frame count of the *source* clip
    # sprite.py puts nb_frames here
    clip_total_frames =
      base["clip_total_frames_source"] ||
        if clip.start_time_seconds && clip.end_time_seconds && fps > 0 do
          Float.ceil((clip.end_time_seconds - clip.start_time_seconds) * fps)
        else
          # fall back – never smaller than tiles
          total_sprite_frames
        end

    # recompute rows only if they weren't stored
    rows = base["rows"] || div(total_sprite_frames + cols - 1, cols)

    %{
      "cols" => cols,
      "rows" => rows,
      "tile_width" => tile_w,
      "tile_height_calculated" => tile_h,
      "total_sprite_frames" => total_sprite_frames,
      "clip_fps" => fps,
      "clip_total_frames" => clip_total_frames,
      "spriteUrl" => cdn_url(art.s3_key),
      "isValid" => true
    }
  end

  defp cdn_url(nil), do: "/images/placeholder_sprite.png"

  defp cdn_url(key) do
    domain =
      Application.get_env(:frontend, :cloudfront_domain) ||
        raise "CloudFront domain not configured. Check runtime.exs and ensure CLOUDFRONT_DEV_DOMAIN or CLOUDFRONT_PROD_DOMAIN is set."

    "https://#{domain}/#{String.trim_leading(key, "/")}"
  end
end
