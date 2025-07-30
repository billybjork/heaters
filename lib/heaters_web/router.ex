defmodule HeatersWeb.Router do
  use HeatersWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {HeatersWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", HeatersWeb do
    pipe_through(:browser)

    get("/", PageController, :home)
    live("/review", ReviewLive)
    live("/query", QueryLive)
    post("/submit_video", VideoController, :create)
  end

  # Video streaming endpoints
  scope "/videos", HeatersWeb do
    # No pipeline - direct HTTP streaming with custom headers
    get("/clips/:clip_id/stream/:version", VideoController, :stream_clip)
    get("/clips/:clip_id/stream", VideoController, :stream_clip)
  end

  # Debug endpoints (development only)
  scope "/debug", HeatersWeb do
    get("/ffmpeg/reset", VideoController, :reset_ffmpeg_pool)
    get("/ffmpeg/status", VideoController, :ffmpeg_pool_status)
  end

  # Other scopes may use custom stacks.
  # scope "/api", HeatersWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:heaters, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: HeatersWeb.Telemetry)
    end
  end
end
