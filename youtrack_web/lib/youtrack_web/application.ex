defmodule YoutrackWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      YoutrackWeb.Telemetry,
      YoutrackWeb.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:youtrack_web, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:youtrack_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: YoutrackWeb.PubSub},
      {YoutrackWeb.RuntimeConfig.Server, name: YoutrackWeb.RuntimeConfig.Server},
      {YoutrackWeb.PromptRegistry, name: YoutrackWeb.PromptRegistry},
      {Task.Supervisor, name: YoutrackWeb.TaskSupervisor},
      YoutrackWeb.FetchCache,
      # Start a worker by calling: Youtrack.Worker.start_link(arg)
      # {Youtrack.Worker, arg},
      # Start to serve requests, typically the last entry
      YoutrackWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: YoutrackWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    YoutrackWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
