defmodule YoutrackWeb.RuntimeConfig do
  @moduledoc false

  alias YoutrackWeb.RuntimeConfig.Server
  alias YoutrackWeb.RuntimeConfigReloader

  @registry_table :youtrack_web_runtime_config_registry
  @topic "config:reloaded"

  def start_link(opts \\ []) do
    Server.start_link(opts)
  end

  def registry_table, do: @registry_table

  def topic, do: @topic

  def snapshot(opts \\ []) do
    server = Keyword.get(opts, :server, Server)

    case table_for(server) do
      nil -> snapshot_from_server_or_loader(server)
      table -> read_snapshot(table)
    end
  end

  def all(opts \\ []), do: snapshot(opts)

  def fetch(key, opts \\ []) do
    server = Keyword.get(opts, :server, Server)

    case table_for(server) do
      nil -> fetch_from_snapshot(snapshot(server: server), key)
      table -> fetch_from_table(table, key)
    end
  end

  def get(key, opts \\ []) do
    default = Keyword.get(opts, :default)

    case fetch(key, opts) do
      {:ok, value} -> value
      :error -> default
    end
  end

  def dashboard_defaults(opts \\ []) do
    get(:dashboard_defaults, Keyword.put_new(opts, :default, %{}))
  end

  def cache_ttl_seconds(opts \\ []) do
    get(:cache_ttl_seconds, Keyword.put_new(opts, :default, 600))
  end

  def report_prompt_files(opts \\ []) do
    get(:report_prompt_files, Keyword.put_new(opts, :default, []))
  end

  def workstream_rules(opts \\ []) do
    get(:workstream_rules, Keyword.put_new(opts, :default, %{}))
  end

  def workstreams_path(opts \\ []) do
    get(:workstreams_path, Keyword.put_new(opts, :default, nil))
  end

  def metadata(opts \\ []) do
    get(:metadata, Keyword.put_new(opts, :default, %{}))
  end

  def reload(opts \\ []) do
    server = Keyword.get(opts, :server, Server)
    reason = Keyword.get(opts, :reason, :manual)

    with true <- server_available?(server),
         {:ok, snapshot} <- GenServer.call(server, {:reload, reason}) do
      {:ok, snapshot}
    else
      false -> RuntimeConfigReloader.load_snapshot()
      {:error, _} = err -> err
      other -> {:error, "reload failed: #{inspect(other)}"}
    end
  end

  def put(key, value, opts \\ []) do
    server = Keyword.get(opts, :server, Server)
    reason = Keyword.get(opts, :reason, {:set, key})

    if server_available?(server) do
      GenServer.call(server, {:put, key, value, reason})
    else
      {:error, "runtime config server unavailable: #{inspect(server)}"}
    end
  end

  def update(update_fun, opts \\ []) when is_function(update_fun, 1) do
    server = Keyword.get(opts, :server, Server)
    reason = Keyword.get(opts, :reason, :update)

    if server_available?(server) do
      GenServer.call(server, {:update, update_fun, reason})
    else
      {:error, "runtime config server unavailable: #{inspect(server)}"}
    end
  end

  def table_for(server \\ Server) do
    case :ets.info(@registry_table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@registry_table, server) do
          [{^server, table}] -> table
          _ -> nil
        end
    end
  end

  defp read_snapshot(table) do
    case :ets.lookup(table, :snapshot) do
      [{:snapshot, snapshot}] -> snapshot
      _ -> %{}
    end
  end

  defp snapshot_from_server_or_loader(server) do
    if server_available?(server) do
      GenServer.call(server, :snapshot)
    else
      case RuntimeConfigReloader.load_snapshot() do
        {:ok, snapshot} -> snapshot
        {:error, _reason} -> %{}
      end
    end
  end

  defp server_available?(server) when is_pid(server), do: Process.alive?(server)

  defp server_available?(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp server_available?(_server), do: false

  defp fetch_from_snapshot(snapshot, key) when is_map(snapshot) do
    case Map.fetch(snapshot, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp fetch_from_table(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      _ -> :error
    end
  end
end
