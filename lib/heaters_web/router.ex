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

    # Serve temporary clip files in development
    get("/temp/:filename", VideoController, :serve_temp_file)
  end

  # Video streaming endpoints removed - using nginx MP4 dynamic clipping
  # Routes moved to nginx service at /proxy/<s3_key>?start=X&end=Y

  # Debug endpoints removed - FFmpeg infrastructure no longer used

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
