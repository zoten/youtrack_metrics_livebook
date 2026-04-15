defmodule YoutrackWeb.Router do
  use YoutrackWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {YoutrackWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", YoutrackWeb do
    pipe_through(:browser)

    live("/", DashboardLive)
    live("/card", CardFocusLive)
    live("/card/:issue_id", CardFocusLive)
    live("/compare", ComparisonLive)
    live("/flow-metrics", FlowMetricsLive)
    live("/gantt", GanttLive)
    live("/pairing", PairingLive)
    live("/weekly-report", WeeklyReportLive)
    live("/workstreams", WorkstreamConfigLive)
    live("/workstream-analyzer", WorkstreamAnalyzerLive)
  end

  # Other scopes may use custom stacks.
  # scope "/api", YoutrackWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:youtrack_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: YoutrackWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
