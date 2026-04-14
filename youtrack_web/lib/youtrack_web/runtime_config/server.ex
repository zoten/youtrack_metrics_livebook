defmodule YoutrackWeb.RuntimeConfig.Server do
  @moduledoc false

  use GenServer

  alias Phoenix.PubSub
  alias YoutrackWeb.RuntimeConfig
  alias YoutrackWeb.RuntimeConfigReloader

  @reload_debounce_ms 250

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      _ -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    loader = Keyword.get(opts, :loader, &RuntimeConfigReloader.load_snapshot/0)
    broadcast? = Keyword.get(opts, :broadcast?, true)
    pubsub = Keyword.get(opts, :pubsub, YoutrackWeb.PubSub)
    topic = Keyword.get(opts, :topic, RuntimeConfig.topic())
    server_key = Keyword.get(opts, :name, self())
    watch? = Keyword.get(opts, :watch?, true)

    ensure_registry_table!()

    state = %{
      loader: loader,
      table: nil,
      snapshot: %{},
      broadcast?: broadcast?,
      pubsub: pubsub,
      topic: topic,
      server_key: server_key,
      watch?: watch?,
      watcher: nil,
      watched_dirs: MapSet.new(),
      reload_timer: nil,
      pending_file_paths: MapSet.new()
    }

    with {:ok, snapshot} <- load_snapshot(loader),
         {:ok, state} <- install_snapshot(state, snapshot, :startup) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.snapshot, state}
  end

  def handle_call({:reload, reason}, _from, state) do
    with {:ok, snapshot} <- load_snapshot(state.loader),
         {:ok, next_state} <- install_snapshot(state, snapshot, reason) do
      {:reply, {:ok, next_state.snapshot}, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put, key, value, reason}, _from, state) do
    snapshot = Map.put(state.snapshot, key, value)

    with {:ok, next_state} <- install_snapshot(state, snapshot, reason) do
      {:reply, :ok, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update, update_fun, reason}, _from, state) do
    case update_fun.(state.snapshot) do
      snapshot when is_map(snapshot) ->
        with {:ok, next_state} <- install_snapshot(state, snapshot, reason) do
          {:reply, {:ok, next_state.snapshot}, next_state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      other ->
        {:reply, {:error, "update must return a map, got: #{inspect(other)}"}, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) when is_binary(path) do
    relevant_paths =
      if relevant_watch_path?(path, state.snapshot) do
        [Path.expand(path)]
      else
        []
      end

    {:noreply, schedule_reload_from_files(state, relevant_paths)}
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    {:noreply, %{state | watcher: nil}}
  end

  def handle_info(:perform_watched_reload, state) do
    pending_paths =
      state.pending_file_paths
      |> MapSet.to_list()
      |> Enum.sort()

    reason = {:file_change, pending_paths}

    next_state = %{
      state
      | reload_timer: nil,
        pending_file_paths: MapSet.new()
    }

    with {:ok, snapshot} <- load_snapshot(next_state.loader),
         {:ok, reloaded_state} <- install_snapshot(next_state, snapshot, reason) do
      {:noreply, reloaded_state}
    else
      {:error, _reason} -> {:noreply, next_state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    unregister_server(state.server_key)
    unregister_server(self())

    if is_pid(state.watcher) and Process.alive?(state.watcher) do
      Process.exit(state.watcher, :normal)
    end

    if is_reference(state.table) or is_atom(state.table) do
      :ets.delete(state.table)
    end

    :ok
  end

  defp load_snapshot(loader) when is_function(loader, 0), do: loader.()

  defp install_snapshot(state, incoming_snapshot, reason) when is_map(incoming_snapshot) do
    previous_snapshot = state.snapshot
    snapshot = normalize_snapshot(incoming_snapshot, previous_snapshot, reason)
    table = build_table(snapshot)

    register_server(state.server_key, table)
    register_server(self(), table)

    if state.table do
      :ets.delete(state.table)
    end

    changed_keys = changed_keys(previous_snapshot, snapshot)
    next_state = %{state | table: table, snapshot: snapshot} |> ensure_watcher()

    broadcast_reload(next_state, changed_keys, reason)

    {:ok, next_state}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp normalize_snapshot(snapshot, previous_snapshot, reason) do
    previous_metadata = Map.get(previous_snapshot, :metadata, %{})
    version = Map.get(previous_metadata, :version, 0) + 1

    metadata =
      snapshot
      |> Map.get(:metadata, %{})
      |> Map.merge(%{
        loaded_at_ms: System.system_time(:millisecond),
        reason: reason,
        version: version
      })

    snapshot
    |> Map.put_new(:dashboard_defaults, %{})
    |> Map.put_new(:cache_ttl_seconds, 600)
    |> Map.put_new(:report_prompt_files, [])
    |> Map.put_new(:workstream_rules, %{})
    |> Map.put_new(:workstreams_path, nil)
    |> Map.put(:metadata, metadata)
  end

  defp build_table(snapshot) do
    table = :ets.new(:runtime_config, [:set, :public, read_concurrency: true])

    entries =
      snapshot
      |> Map.to_list()
      |> Enum.map(fn {key, value} -> {key, value} end)

    :ets.insert(table, [{:snapshot, snapshot} | entries])
    table
  end

  defp changed_keys(previous_snapshot, snapshot) do
    keys =
      Map.keys(previous_snapshot)
      |> Enum.concat(Map.keys(snapshot))
      |> Enum.uniq()

    Enum.reject(keys, fn key -> Map.get(previous_snapshot, key) == Map.get(snapshot, key) end)
  end

  defp broadcast_reload(%{broadcast?: false}, _changed_keys, _reason), do: :ok
  defp broadcast_reload(%{pubsub: nil}, _changed_keys, _reason), do: :ok

  defp broadcast_reload(state, changed_keys, reason) do
    payload = %{
      changed_keys: changed_keys,
      reason: reason,
      version: get_in(state.snapshot, [:metadata, :version])
    }

    PubSub.broadcast(state.pubsub, state.topic, {:config_reloaded, payload})

    if workstreams_changed?(changed_keys) do
      PubSub.broadcast(state.pubsub, "workstreams:updated", :workstreams_updated)
    end

    :ok
  end

  defp workstreams_changed?(changed_keys) do
    Enum.any?(changed_keys, &(&1 in [:workstream_rules, :workstreams_path, :dashboard_defaults]))
  end

  defp ensure_watcher(%{watch?: false} = state), do: state

  defp ensure_watcher(state) do
    dirs = watched_directories(state.snapshot)

    case {state.watcher, dirs == state.watched_dirs} do
      {watcher, true} when is_pid(watcher) ->
        state

      {watcher, _} when is_pid(watcher) ->
        Process.exit(watcher, :normal)
        start_watcher(state, dirs)

      _ ->
        start_watcher(state, dirs)
    end
  end

  defp start_watcher(state, dirs) do
    if MapSet.size(dirs) == 0 or not Code.ensure_loaded?(FileSystem) do
      %{state | watcher: nil, watched_dirs: dirs}
    else
      watch_dirs = MapSet.to_list(dirs)

      case FileSystem.start_link(dirs: watch_dirs) do
        {:ok, watcher} ->
          FileSystem.subscribe(watcher)
          %{state | watcher: watcher, watched_dirs: dirs}

        _ ->
          %{state | watcher: nil, watched_dirs: dirs}
      end
    end
  end

  defp watched_directories(snapshot) do
    dotenv_dirs =
      RuntimeConfigReloader.dotenv_paths()
      |> Enum.map(&Path.expand/1)
      |> Enum.map(&Path.dirname/1)

    workstreams_dirs =
      case Map.get(snapshot, :workstreams_path) do
        path when is_binary(path) and path != "" -> [Path.dirname(Path.expand(path))]
        _ -> []
      end

    (dotenv_dirs ++ workstreams_dirs)
    |> Enum.filter(&File.dir?/1)
    |> MapSet.new()
  end

  defp relevant_watch_path?(path, snapshot) when is_binary(path) do
    expanded = Path.expand(path)
    workstreams_path = Map.get(snapshot, :workstreams_path)

    Path.basename(expanded) == ".env" or
      workstreams_match?(expanded, workstreams_path)
  end

  defp relevant_watch_path?(_path, _snapshot), do: false

  defp workstreams_match?(_expanded, path) when path in [nil, ""], do: false

  defp workstreams_match?(expanded, path) do
    expanded == Path.expand(path)
  end

  defp schedule_reload_from_files(state, []), do: state

  defp schedule_reload_from_files(state, paths) do
    pending_paths = Enum.reduce(paths, state.pending_file_paths, &MapSet.put(&2, &1))

    reload_timer =
      case state.reload_timer do
        nil -> Process.send_after(self(), :perform_watched_reload, @reload_debounce_ms)
        timer -> timer
      end

    %{state | pending_file_paths: pending_paths, reload_timer: reload_timer}
  end

  defp ensure_registry_table!() do
    case :ets.info(RuntimeConfig.registry_table()) do
      :undefined ->
        :ets.new(RuntimeConfig.registry_table(), [
          :named_table,
          :public,
          :set,
          read_concurrency: true
        ])

      _ ->
        :ok
    end

    :ok
  end

  defp register_server(server_key, table) do
    :ets.insert(RuntimeConfig.registry_table(), {server_key, table})
  end

  defp unregister_server(server_key) do
    case :ets.info(RuntimeConfig.registry_table()) do
      :undefined -> :ok
      _ -> :ets.delete(RuntimeConfig.registry_table(), server_key)
    end
  end
end
