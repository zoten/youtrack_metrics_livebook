defmodule YoutrackWeb.PromptRegistry do
  @moduledoc false

  use GenServer

  alias Phoenix.PubSub
  alias YoutrackWeb.RuntimeConfig

  @table :youtrack_web_prompt_registry
  @topic "prompts:updated"
  @reload_debounce_ms 250

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def topic, do: @topic

  def prompt_files(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    case read_files_from_table() do
      {:ok, files} -> files
      :error -> GenServer.call(server, :prompt_files)
    end
  end

  def list_prompt_files(path, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:list_prompt_files, path})
  end

  def refresh(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :refresh)
  end

  @impl true
  def init(opts) do
    watch? = Keyword.get(opts, :watch?, true)
    listen_config? = Keyword.get(opts, :listen_config?, true)
    pubsub = Keyword.get(opts, :pubsub, YoutrackWeb.PubSub)

    ensure_table!()

    if listen_config? and pubsub != nil do
      PubSub.subscribe(pubsub, RuntimeConfig.topic())
    end

    prompts_path = RuntimeConfig.dashboard_defaults()["prompts_path"] || ""
    files = discover_prompt_files(prompts_path)
    write_snapshot(prompts_path, files)

    state = %{
      pubsub: pubsub,
      watch?: watch?,
      prompts_path: prompts_path,
      files: files,
      watcher: nil,
      reload_timer: nil
    }

    {:ok, ensure_watcher(state)}
  end

  @impl true
  def handle_call(:prompt_files, _from, state) do
    {:reply, state.files, state}
  end

  def handle_call({:list_prompt_files, path}, _from, state) do
    {:reply, discover_prompt_files(path), state}
  end

  def handle_call(:refresh, _from, state) do
    refreshed = refresh_state(state)
    {:reply, {:ok, refreshed.files}, refreshed}
  end

  @impl true
  def handle_info({:config_reloaded, _payload}, state) do
    prompts_path = RuntimeConfig.dashboard_defaults()["prompts_path"] || ""

    if prompts_path == state.prompts_path do
      {:noreply, state}
    else
      next_state = %{state | prompts_path: prompts_path} |> refresh_state()
      {:noreply, ensure_watcher(next_state)}
    end
  end

  def handle_info({:file_event, _watcher, {path, _events}}, state) when is_binary(path) do
    if relevant_path?(path, state.prompts_path) do
      timer =
        case state.reload_timer do
          nil -> Process.send_after(self(), :refresh_from_watch, @reload_debounce_ms)
          existing -> existing
        end

      {:noreply, %{state | reload_timer: timer}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher, :stop}, state) do
    {:noreply, %{state | watcher: nil}}
  end

  def handle_info(:refresh_from_watch, state) do
    next_state =
      state
      |> Map.put(:reload_timer, nil)
      |> refresh_state()

    {:noreply, next_state}
  end

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.watcher) and Process.alive?(state.watcher) do
      Process.exit(state.watcher, :normal)
    end

    :ok
  end

  defp refresh_state(state) do
    files = discover_prompt_files(state.prompts_path)
    write_snapshot(state.prompts_path, files)
    broadcast_updated(state.pubsub, state.prompts_path, files)
    %{state | files: files}
  end

  defp ensure_watcher(%{watch?: false} = state), do: state

  defp ensure_watcher(state) do
    path = to_string(state.prompts_path || "")

    if path == "" or not File.dir?(path) or not Code.ensure_loaded?(FileSystem) do
      stop_watcher(state)
    else
      expanded = Path.expand(path)

      case state.watcher do
        watcher when is_pid(watcher) ->
          if Process.alive?(watcher) do
            state
          else
            start_watcher_for_path(state, expanded)
          end

        _ ->
          start_watcher_for_path(state, expanded)
      end
    end
  end

  defp stop_watcher(state) do
    if is_pid(state.watcher) and Process.alive?(state.watcher) do
      Process.exit(state.watcher, :normal)
    end

    %{state | watcher: nil}
  end

  defp start_watcher_for_path(state, expanded) do
    case FileSystem.start_link(dirs: [expanded]) do
      {:ok, watcher} ->
        FileSystem.subscribe(watcher)
        %{state | watcher: watcher}

      _ ->
        %{state | watcher: nil}
    end
  end

  defp relevant_path?(path, prompts_path) do
    expanded = Path.expand(path)
    root = Path.expand(to_string(prompts_path || ""))

    String.starts_with?(expanded, root) and
      (File.regular?(expanded) or String.ends_with?(expanded, [".txt", ".md", ".prompt"]))
  end

  defp discover_prompt_files(prompts_path) do
    path = to_string(prompts_path || "")

    if path == "" or not File.dir?(path) do
      []
    else
      path
      |> File.ls!()
      |> Enum.filter(fn file ->
        String.ends_with?(file, [".txt", ".md", ".prompt"]) or String.contains?(file, ".prompt.")
      end)
      |> Enum.map(fn file ->
        %{
          id: "file:" <> file,
          label: file,
          path: Path.join(path, file)
        }
      end)
      |> Enum.sort_by(& &1.label)
    end
  end

  defp ensure_table! do
    case :ets.info(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      _ -> :ok
    end

    :ok
  end

  defp write_snapshot(path, files) do
    now = System.system_time(:millisecond)
    :ets.insert(@table, [{:path, path}, {:files, files}, {:updated_at_ms, now}])
    :ok
  end

  defp read_files_from_table do
    case :ets.info(@table) do
      :undefined ->
        :error

      _ ->
        case :ets.lookup(@table, :files) do
          [{:files, files}] -> {:ok, files}
          _ -> :error
        end
    end
  end

  defp broadcast_updated(nil, _path, _files), do: :ok

  defp broadcast_updated(pubsub, path, files) do
    PubSub.broadcast(pubsub, @topic, {:prompts_updated, %{path: path, count: length(files)}})
  end
end
