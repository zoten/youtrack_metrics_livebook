defmodule YoutrackWeb.WorkstreamAnalyzerLive do
  @moduledoc """
  Workstream Analyzer LiveView.

  Focuses on effort-over-time analysis with two modes:
  - compare: multiple workstreams in one chart
  - composition: parent stream split by substreams
  """

  use YoutrackWeb, :live_view

  alias Youtrack.Client
  alias Youtrack.StartAt
  alias Youtrack.WorkItems
  alias Youtrack.WorkstreamsLoader
  alias YoutrackWeb.Charts.WorkstreamAnalyzer, as: WorkstreamAnalyzerCharts
  alias YoutrackWeb.Configuration
  alias YoutrackWeb.ConfigVisibilityPreference
  alias YoutrackWeb.EffortMappingsLoader
  alias YoutrackWeb.EffortNormalization
  alias YoutrackWeb.RuntimeConfig
  alias YoutrackWeb.WorkstreamAnalyzer

  @impl true
  def mount(_params, _session, socket) do
    defaults =
      Configuration.defaults()
      |> Configuration.merge_shared(Configuration.shared_from_socket(socket))

    config_open? = ConfigVisibilityPreference.from_socket(socket)

    socket =
      socket
      |> assign(:current_scope, nil)
      |> assign(:page_title, "Workstream Analyzer")
      |> assign(:config_open?, config_open?)
      |> assign(:loading?, false)
      |> assign(:fetch_error, nil)
      |> assign(:fetch_cache_state, nil)
      |> assign(:mode, "compare")
      |> assign(:available_streams, [])
      |> assign(:selected_streams, [])
      |> assign(:parent_stream, nil)
      |> assign(:config, defaults)
      |> assign(:config_form, to_form(defaults, as: :config))
      |> assign(:chart_specs, %{})
      |> assign(:metrics, %{})
      |> assign(:normalization_diagnostics, %{})
      |> assign(:composition_cards, %{})
      |> assign(:cached_work_items, [])
      |> assign(:cached_normalized_results, [])
      |> assign(:cached_rules, %{})

    if connected?(socket) do
      Phoenix.PubSub.subscribe(YoutrackWeb.PubSub, "workstreams:updated")
      Phoenix.PubSub.subscribe(YoutrackWeb.PubSub, RuntimeConfig.topic())
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_config", _params, socket) do
    config_open? = !socket.assigns.config_open?

    {:noreply,
     socket
     |> assign(:config_open?, config_open?)
     |> push_event("config_visibility_changed", %{open: config_open?})}
  end

  @impl true
  def handle_event("config_changed", %{"config" => params}, socket) do
    config = Configuration.merge_shared(socket.assigns.config, params)

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:config_form, to_form(config, as: :config))}
  end

  @impl true
  def handle_event("fetch_data", params, socket) do
    refresh? = params["refresh"] == "true"

    case validate_config(socket.assigns.config) do
      :ok ->
        {:noreply,
         socket
         |> assign(:loading?, true)
         |> assign(:fetch_error, nil)
         |> start_fetch_task(socket.assigns.config, refresh?)}

      {:error, message} ->
        {:noreply, assign(socket, :fetch_error, message)}
    end
  end

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) do
    mode = sanitize_mode(mode)

    {:noreply,
     socket
     |> assign(:mode, mode)
     |> rebuild_from_cached()}
  end

  @impl true
  def handle_event("selected_streams_changed", %{"selected_streams" => selected}, socket) do
    selected_streams = sanitize_selected_streams(selected, socket.assigns.available_streams)

    {:noreply,
     socket
     |> assign(:selected_streams, selected_streams)
     |> rebuild_from_cached()}
  end

  @impl true
  def handle_event("selected_streams_changed", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_streams, [])
     |> rebuild_from_cached()}
  end

  @impl true
  def handle_event("set_all_streams", %{"selection" => selection}, socket) do
    selected_streams =
      case selection do
        "all" -> socket.assigns.available_streams
        "none" -> []
        _ -> socket.assigns.selected_streams
      end

    {:noreply,
     socket
     |> assign(:selected_streams, selected_streams)
     |> rebuild_from_cached()}
  end

  @impl true
  def handle_event("parent_stream_changed", %{"parent_stream" => parent_stream}, socket) do
    parent_stream =
      case String.trim(parent_stream || "") do
        "" -> nil
        value -> value
      end

    {:noreply,
     socket
     |> assign(:parent_stream, parent_stream)
     |> rebuild_from_cached()}
  end

  @impl true
  def handle_event("clear_cache", _params, socket) do
    :ok = YoutrackWeb.FetchCache.clear()

    {:noreply,
     socket
     |> assign(:fetch_cache_state, nil)
     |> put_flash(:info, "Cache cleared")}
  end

  @impl true
  def handle_event("reload_config", _params, socket) do
    case Configuration.reload_defaults() do
      {:ok, defaults} ->
        {:noreply,
         socket
         |> assign(:config, defaults)
         |> assign(:config_form, to_form(defaults, as: :config))
         |> put_flash(:info, "Reloaded .env and config files")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reload failed: #{reason}")}
    end
  end

  @impl true
  def handle_info({ref, {:ok, result}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:chart_specs, result.chart_specs)
     |> assign(:metrics, result.metrics)
     |> assign(:fetch_cache_state, result.fetch_cache_state)
     |> assign(:available_streams, result.available_streams)
     |> assign(:selected_streams, result.selected_streams)
     |> assign(:parent_stream, result.parent_stream)
     |> assign(:normalization_diagnostics, result.normalization_diagnostics)
     |> assign(:cached_work_items, result.cached_work_items)
     |> assign(:cached_normalized_results, result.cached_normalized_results)
     |> assign(:cached_rules, result.cached_rules)
     |> assign(:composition_cards, result.composition_cards)
     |> assign(:mode, result.mode)}
  end

  @impl true
  def handle_info({ref, {:error, reason}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:fetch_error, "Workstream analyzer fetch failed: #{reason}")}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:fetch_error, "Background task crashed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info(:workstreams_updated, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Workstream rules updated — fetch again to refresh analyzer")}
  end

  @impl true
  def handle_info({:config_reloaded, payload}, socket) do
    defaults = Configuration.defaults()
    config = Configuration.merge_shared(defaults, socket.assigns.config)

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:config_form, to_form(config, as: :config))
     |> put_flash(:info, config_reload_message(payload[:reason]))}
  end

  defp start_fetch_task(socket, config, refresh?) do
    owner_pid = self()

    filters = %{
      mode: socket.assigns.mode,
      selected_streams: socket.assigns.selected_streams,
      parent_stream: socket.assigns.parent_stream
    }

    task =
      Task.Supervisor.async_nolink(YoutrackWeb.TaskSupervisor, fn ->
        fetch_and_build(config, filters, owner_pid, refresh?)
      end)

    assign(socket, :fetch_task_ref, task.ref)
  end

  defp validate_config(config) do
    cond do
      blank?(config["base_url"]) -> {:error, "Base URL is required"}
      blank?(config["token"]) -> {:error, "Token is required"}
      blank?(config["base_query"]) -> {:error, "Base query is required"}
      true -> :ok
    end
  end

  defp fetch_and_build(config, filters, owner_pid, refresh?) do
    _ = owner_pid

    base_url = String.trim(config["base_url"] || "")
    token = String.trim(config["token"] || "")
    base_query = String.trim(config["base_query"] || "")
    days_back = parse_int(config["days_back"], 14)

    state_field = String.trim(config["state_field"] || "State")
    assignees_field = String.trim(config["assignees_field"] || "Assignees")
    in_progress_names = csv_list(config["in_progress_names"])
    excluded_logins = csv_list(config["excluded_logins"])

    use_activities? = parse_bool(config["use_activities"])
    include_substreams? = parse_bool(config["include_substreams"])

    project_prefix = String.trim(config["project_prefix"] || "")
    unplanned_tag = String.trim(config["unplanned_tag"] || "")
    workstreams_path = String.trim(config["workstreams_path"] || "")
    effort_mappings_path = String.trim(config["effort_mappings_path"] || "")

    req = Client.new!(base_url, token)

    today = Date.utc_today() |> Date.to_iso8601()
    start_date = Date.utc_today() |> Date.add(-days_back) |> Date.to_iso8601()
    query = "#{base_query} updated: #{start_date} .. #{today}"

    cache_key = {:workstream_analyzer_issues, base_url, query}

    {:ok, raw_issues, cache_state} =
      YoutrackWeb.FetchCache.get_or_fetch(
        cache_key,
        fn -> Client.fetch_issues!(req, query) end,
        refresh: refresh?
      )

    issues = filter_by_project_prefix(raw_issues, project_prefix)
    rules = load_rules(workstreams_path)
    effort_mappings = load_effort_mappings(effort_mappings_path)

    issue_start_at =
      if use_activities? do
        fetch_issue_start_at(req, issues, state_field, in_progress_names)
      else
        %{}
      end

    work_items =
      WorkItems.build(
        issues,
        state_field: state_field,
        assignees_field: assignees_field,
        rules: rules,
        in_progress_names: in_progress_names,
        issue_start_at: issue_start_at,
        excluded_logins: excluded_logins,
        include_substreams: include_substreams?,
        unplanned_tag: maybe_nil(unplanned_tag)
      )

    normalization = EffortNormalization.normalize_issues(issues, effort_mappings)

    available_streams =
      work_items
      |> Enum.map(& &1.stream)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    selected_streams =
      case filters.selected_streams do
        list when is_list(list) and list != [] ->
          sanitize_selected_streams(list, available_streams)

        _ ->
          available_streams
      end

    parent_stream =
      case filters.parent_stream do
        value when is_binary(value) and value != "" -> value
        _ -> default_parent_stream(rules, available_streams)
      end

    mode = sanitize_mode(filters.mode)

    analysis =
      WorkstreamAnalyzer.build(
        work_items,
        normalization.results,
        rules,
        selected_streams: selected_streams,
        parent_stream: parent_stream
      )

    chart_specs = WorkstreamAnalyzerCharts.build_chart_specs(analysis)

    metrics = %{
      total_issues: length(issues),
      total_work_items: length(work_items),
      normalized_issue_count: normalization.diagnostics.mapped_count,
      unmapped_issue_count: normalization.diagnostics.unmapped_count,
      attributed_issue_count: analysis.diagnostics.attributed_issue_count,
      attribution_anomaly_count: analysis.diagnostics.attribution_anomaly_count
    }

    {:ok,
     %{
       chart_specs: chart_specs,
       metrics: metrics,
       fetch_cache_state: cache_state,
       available_streams: available_streams,
       selected_streams: selected_streams,
       parent_stream: parent_stream,
       mode: mode,
       normalization_diagnostics: normalization.diagnostics,
       cached_work_items: work_items,
       cached_normalized_results: normalization.results,
       cached_rules: rules,
       composition_cards: analysis.composition_cards
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp rebuild_from_cached(socket) do
    if socket.assigns.cached_work_items == [] do
      socket
    else
      analysis =
        WorkstreamAnalyzer.build(
          socket.assigns.cached_work_items,
          socket.assigns.cached_normalized_results,
          socket.assigns.cached_rules,
          selected_streams: socket.assigns.selected_streams,
          parent_stream: socket.assigns.parent_stream
        )

      metrics =
        socket.assigns.metrics
        |> Map.put(:attributed_issue_count, analysis.diagnostics.attributed_issue_count)
        |> Map.put(:attribution_anomaly_count, analysis.diagnostics.attribution_anomaly_count)

      socket
      |> assign(:chart_specs, WorkstreamAnalyzerCharts.build_chart_specs(analysis))
      |> assign(:metrics, metrics)
      |> assign(:composition_cards, analysis.composition_cards)
    end
  end

  defp fetch_issue_start_at(req, issues, state_field, in_progress_names) do
    issues
    |> Task.async_stream(
      fn issue ->
        id = issue["id"]
        activities = Client.fetch_activities!(req, id)
        {id, StartAt.from_activities(activities, state_field, in_progress_names)}
      end,
      ordered: false,
      timeout: :infinity,
      max_concurrency: 8
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, start_at}}, acc when is_integer(start_at) -> Map.put(acc, id, start_at)
      _, acc -> acc
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_scope}
      config={@config}
      config_form={@config_form}
      config_open?={@config_open?}
      active_section="workstream_analyzer"
      freshness={@fetch_cache_state}
      topbar_label="Workstream Analyzer"
      topbar_hint="Effort-over-time comparison and substream composition from normalized effort."
    >
      <div class="space-y-6 pb-10">
        <div class="metrics-card-strong rounded-[2rem] px-6 py-6 sm:px-8">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p class="metrics-eyebrow text-xs uppercase tracking-[0.28em]">Section</p>
              <h2 class="metrics-brand metrics-title mt-2 text-4xl leading-none">
                Workstream Analyzer
              </h2>
              <p class="metrics-copy mt-3">
                Normalize mixed effort schemes and compare trends or composition in one page.
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                id="toggle-workstream-analyzer-config"
                type="button"
                phx-click="toggle_config"
                class="metrics-button metrics-button-secondary"
              >
                {if(@config_open?, do: "Hide config", else: "Show config")}
              </button>
              <button
                id="fetch-workstream-analyzer-data"
                type="button"
                phx-click="fetch_data"
                class="metrics-button metrics-button-primary font-semibold"
              >
                Fetch (cache)
              </button>
              <button
                id="fetch-workstream-analyzer-data-refresh"
                type="button"
                phx-click="fetch_data"
                phx-value-refresh="true"
                class="metrics-button metrics-button-secondary"
              >
                Refresh (API)
              </button>
              <button
                id="reload-workstream-analyzer-config"
                type="button"
                phx-click="reload_config"
                class="metrics-button metrics-button-secondary"
              >
                Reload Configuration
              </button>
              <button
                id="clear-workstream-analyzer-cache"
                type="button"
                phx-click="clear_cache"
                class="metrics-button metrics-button-ghost"
              >
                Clear cache
              </button>
            </div>
          </div>

          <%= if @fetch_cache_state do %>
            <p
              id="workstream-analyzer-cache-state"
              class="metrics-eyebrow mt-3 text-xs uppercase tracking-[0.2em]"
            >
              Last fetch source: {cache_state_label(@fetch_cache_state)}
            </p>
          <% end %>
        </div>

        <%= if @fetch_error do %>
          <div class="metrics-card rounded-[2rem] border border-red-400/30 bg-red-500/10 p-5 text-red-200">
            {@fetch_error}
          </div>
        <% end %>

        <%= if @loading? do %>
          <div class="metrics-card metrics-copy rounded-[2rem] p-10 text-center">
            <div class="mx-auto mb-4 h-10 w-10 animate-spin rounded-full border-4 border-stone-700 border-t-orange-400">
            </div>
            <p>Fetching issues and building normalized effort datasets...</p>
          </div>
        <% end %>

        <div class="metrics-grid">
          <.stat_card label="Issues" value={metric(@metrics, :total_issues)} tone="neutral" />
          <.stat_card
            label="Work items"
            value={metric(@metrics, :total_work_items)}
            tone="neutral"
          />
          <.stat_card
            label="Normalized"
            value={metric(@metrics, :normalized_issue_count)}
            tone="success"
          />
          <.stat_card
            label="Unmapped"
            value={metric(@metrics, :unmapped_issue_count)}
            tone="warning"
          />
          <.stat_card
            label="Attributed"
            value={metric(@metrics, :attributed_issue_count)}
            tone="accent"
          />
          <.stat_card
            label="Attribution anomalies"
            value={metric(@metrics, :attribution_anomaly_count)}
            tone="warning"
          />
        </div>

        <div class="metrics-card rounded-[2rem] p-6">
          <p class="metrics-eyebrow text-xs uppercase tracking-[0.24em]">View controls</p>

          <div class="mt-3 flex flex-wrap gap-2">
            <button
              id="workstream-analyzer-mode-compare"
              type="button"
              phx-click="set_mode"
              phx-value-mode="compare"
              class={[
                "metrics-button",
                @mode == "compare" && "metrics-button-primary",
                @mode != "compare" && "metrics-button-secondary"
              ]}
            >
              Compare
            </button>
            <button
              id="workstream-analyzer-mode-composition"
              type="button"
              phx-click="set_mode"
              phx-value-mode="composition"
              class={[
                "metrics-button",
                @mode == "composition" && "metrics-button-primary",
                @mode != "composition" && "metrics-button-secondary"
              ]}
            >
              Composition
            </button>
          </div>

          <%= if @available_streams != [] do %>
            <%= if @mode == "compare" do %>
              <div class="mt-4 flex flex-wrap gap-2">
                <button
                  id="workstream-analyzer-select-all-streams"
                  type="button"
                  phx-click="set_all_streams"
                  phx-value-selection="all"
                  class="metrics-button metrics-button-secondary"
                >
                  Select all
                </button>
                <button
                  id="workstream-analyzer-unselect-all-streams"
                  type="button"
                  phx-click="set_all_streams"
                  phx-value-selection="none"
                  class="metrics-button metrics-button-secondary"
                >
                  Unselect all
                </button>
              </div>

              <.form
                for={%{}}
                as={:filters}
                id="workstream-analyzer-stream-filter"
                phx-change="selected_streams_changed"
                class="mt-4 grid gap-2 sm:grid-cols-2 lg:grid-cols-3"
              >
                <%= for stream <- @available_streams do %>
                  <label class="metrics-copy flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      name="selected_streams[]"
                      value={stream}
                      checked={stream in @selected_streams}
                    /> {stream}
                  </label>
                <% end %>
              </.form>
            <% else %>
              <div class="mt-4 max-w-sm">
                <.form for={%{}} as={:filters} phx-change="parent_stream_changed">
                  <label class="metrics-copy mb-1 block text-sm">Parent stream</label>
                  <select
                    id="workstream-analyzer-parent-stream"
                    name="parent_stream"
                    class="input input-bordered w-full"
                  >
                    <option value="">Choose parent stream</option>
                    <%= for stream <- @available_streams do %>
                      <option value={stream} selected={@parent_stream == stream}>{stream}</option>
                    <% end %>
                  </select>
                </.form>
              </div>
            <% end %>
          <% end %>
        </div>

        <%= if @mode == "compare" and @chart_specs[:compare_effort] do %>
          <.chart_card
            id="chart-workstream-compare"
            title="Effort over time by workstream"
            description="Compare selected streams on a single normalized effort timeline."
            spec={@chart_specs.compare_effort}
            class="h-[28rem]"
            wrapper_class="md:col-span-2"
          />
        <% end %>

        <%= if @mode == "composition" and @chart_specs[:composition_effort] do %>
          <.chart_card
            id="chart-workstream-composition"
            title="Substream composition over time"
            description="Stacked normalized effort by substream with total overlay."
            spec={@chart_specs.composition_effort}
            class="h-[28rem]"
            wrapper_class="md:col-span-2"
          />
        <% end %>

        <%= if @mode == "composition" and @parent_stream && map_size(@composition_cards) > 0 do %>
          <div id="workstream-analyzer-composition-cards" class="metrics-card rounded-[2rem] p-6 md:col-span-2">
            <p class="metrics-eyebrow text-xs uppercase tracking-[0.24em]">Card composition</p>
            <div class="mt-4 space-y-4">
              <%= for {bucket, issue_ids} <- Enum.sort_by(@composition_cards, fn {bucket, _} -> {bucket != "(direct)", bucket} end) do %>
                <div>
                  <p class="metrics-copy mb-2 text-sm font-medium">{bucket}</p>
                  <div class="flex flex-wrap gap-2">
                    <%= for issue_id <- issue_ids do %>
                      <a
                        href={"https://#{@config["base_url"]}/youtrack/issue/#{issue_id}"}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="metrics-pill metrics-pill-accent px-3 py-2 text-xs tracking-normal hover:underline"
                      >
                        {issue_id}
                      </a>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <div id="workstream-analyzer-diagnostics" class="metrics-card rounded-[2rem] p-6">
          <p class="metrics-eyebrow text-xs uppercase tracking-[0.24em]">Normalization diagnostics</p>
          <p id="workstream-analyzer-effort-mappings-path" class="metrics-copy mt-2 text-xs">
            Effort mappings path: {@config["effort_mappings_path"] || "(default)"}
          </p>

          <div class="metrics-copy mt-4 grid gap-3 text-sm md:grid-cols-3">
            <div>
              <p>Mapped by field</p>
              <div class="metrics-code mt-2 rounded-xl bg-black/20 p-3 text-xs">
                <pre>{Jason.encode_to_iodata!(Map.get(@normalization_diagnostics, :mapped_by_field, %{}), pretty: true)}</pre>
              </div>
            </div>
            <div>
              <p>Unmapped by reason</p>
              <div class="metrics-code mt-2 rounded-xl bg-black/20 p-3 text-xs">
                <pre>{Jason.encode_to_iodata!(Map.get(@normalization_diagnostics, :unmapped_by_reason, %{}), pretty: true)}</pre>
              </div>
            </div>
            <div>
              <p>Unmapped samples</p>
              <div class="metrics-code mt-2 rounded-xl bg-black/20 p-3 text-xs">
                <pre>{Jason.encode_to_iodata!(Map.get(@normalization_diagnostics, :unmapped_samples, []), pretty: true)}</pre>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:tone, :string, default: "neutral")

  defp stat_card(assigns) do
    ~H"""
    <div class={[
      "rounded-[1.5rem] border px-4 py-4",
      stat_card_classes(@tone)
    ]}>
      <p class="metrics-stat-label text-xs uppercase tracking-[0.22em]">{@label}</p>
      <p class="metrics-stat-value mt-3 text-xl font-semibold">{@value}</p>
    </div>
    """
  end

  defp stat_card_classes("accent"), do: "metrics-pill-accent"
  defp stat_card_classes("success"), do: "metrics-pill-success"
  defp stat_card_classes("warning"), do: "metrics-pill-warning"
  defp stat_card_classes(_tone), do: "metrics-pill-muted"

  defp metric(metrics, key) do
    metrics
    |> Map.get(key, 0)
    |> metric_value()
  end

  defp metric_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp metric_value(value), do: to_string(value)

  defp load_rules("") do
    RuntimeConfig.workstream_rules()
  end

  defp load_rules(path) do
    if RuntimeConfig.workstreams_path() == path do
      RuntimeConfig.workstream_rules()
    else
      case WorkstreamsLoader.load_file(path) do
        {:ok, rules} -> rules
        {:error, _reason} -> WorkstreamsLoader.empty_rules()
      end
    end
  end

  defp load_effort_mappings("") do
    RuntimeConfig.effort_mappings()
  end

  defp load_effort_mappings(path) do
    if RuntimeConfig.effort_mappings_path() == path do
      RuntimeConfig.effort_mappings()
    else
      case EffortMappingsLoader.load_file(path) do
        {:ok, mappings} -> mappings
        {:error, _reason} -> EffortMappingsLoader.empty_mappings()
      end
    end
  end

  defp sanitize_mode("composition"), do: "composition"
  defp sanitize_mode(_), do: "compare"

  defp sanitize_selected_streams(selected_streams, available_streams) do
    selected_streams
    |> List.wrap()
    |> Enum.filter(&(&1 in available_streams))
    |> Enum.uniq()
  end

  defp default_parent_stream(rules, available_streams) do
    parent_streams =
      rules
      |> Map.get(:substream_of, %{})
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      parent_streams != [] -> hd(parent_streams)
      available_streams != [] -> hd(available_streams)
      true -> nil
    end
  end

  defp filter_by_project_prefix(issues, ""), do: issues

  defp filter_by_project_prefix(issues, prefix) do
    Enum.filter(issues, fn issue ->
      String.starts_with?(issue["idReadable"] || "", prefix)
    end)
  end

  defp cache_state_label(%{source: source}), do: cache_state_label(source)
  defp cache_state_label(:hit), do: "cache hit"
  defp cache_state_label(:miss), do: "cache miss"
  defp cache_state_label(:refresh), do: "refresh"
  defp cache_state_label(_), do: "unknown"

  defp config_reload_message({:file_change, _paths}),
    do: "Configuration changed on disk and was reloaded"

  defp config_reload_message(:manual), do: "Configuration reloaded"
  defp config_reload_message(_), do: "Configuration updated"

  defp parse_int(nil, default), do: default

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp parse_bool(value) when value in [true, "true", "1", 1], do: true
  defp parse_bool(_), do: false

  defp csv_list(nil), do: []

  defp csv_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp csv_list(_), do: []

  defp blank?(value), do: value |> to_string() |> String.trim() == ""

  defp maybe_nil(value) do
    trimmed = String.trim(value || "")
    if trimmed == "", do: nil, else: trimmed
  end
end
