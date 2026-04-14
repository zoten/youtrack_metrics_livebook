defmodule YoutrackWeb.FlowMetricsLive do
  @moduledoc """
  Flow Metrics LiveView section.

  Mirrors the core metrics from `flow_metrics.livemd` and renders charts
  through the VegaLite hook.
  """

  use YoutrackWeb, :live_view

  alias Youtrack.Client
  alias Youtrack.Rework
  alias Youtrack.Rotation
  alias Youtrack.StartAt
  alias Youtrack.WeeklyReport
  alias Youtrack.WorkItems
  alias Youtrack.WorkstreamsLoader
  alias YoutrackWeb.Charts.FlowMetrics, as: FlowMetricsCharts
  alias YoutrackWeb.Configuration
  alias YoutrackWeb.ConfigVisibilityPreference
  alias YoutrackWeb.RuntimeConfig

  @impl true
  def mount(_params, _session, socket) do
    defaults =
      Configuration.defaults()
      |> Configuration.merge_shared(Configuration.shared_from_socket(socket))

    config_open? = ConfigVisibilityPreference.from_socket(socket)

    socket =
      socket
      |> assign(:current_scope, nil)
      |> assign(:page_title, "Flow Metrics")
      |> assign(:config_open?, config_open?)
      |> assign(:loading?, false)
      |> assign(:activity_progress, nil)
      |> assign(:fetch_error, nil)
      |> assign(:fetch_cache_state, nil)
      |> assign(:config, defaults)
      |> assign(:config_form, to_form(defaults, as: :config))
      |> assign(:chart_specs, %{})
      |> assign(:metrics, %{})

    if connected?(socket) do
      send(self(), :maybe_auto_fetch)
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
        use_activities? = parse_bool(socket.assigns.config["use_activities"])

        {:noreply,
         socket
         |> assign(:loading?, true)
         |> assign(:activity_progress, if(use_activities?, do: %{done: 0, total: 0}, else: nil))
         |> assign(:fetch_error, nil)
         |> start_fetch_task(socket.assigns.config, refresh?)}

      {:error, message} ->
        {:noreply, assign(socket, :fetch_error, message)}
    end
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
         |> put_flash(:info, "Reloaded .env and workstreams.yaml")}

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
     |> assign(:activity_progress, nil)
     |> assign(:chart_specs, result.chart_specs)
     |> assign(:metrics, result.metrics)
     |> assign(:fetch_cache_state, Map.get(result, :fetch_cache_state))}
  end

  @impl true
  def handle_info({ref, {:error, reason}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:activity_progress, nil)
     |> assign(:fetch_error, "Flow metrics fetch failed: #{reason}")}
  end

  @impl true
  def handle_info({:activities_progress, done, total}, socket) do
    {:noreply, assign(socket, :activity_progress, %{done: done, total: total})}
  end

  @impl true
  def handle_info(:maybe_auto_fetch, socket) do
    cond do
      socket.assigns.loading? ->
        {:noreply, socket}

      map_size(socket.assigns.chart_specs) > 0 ->
        {:noreply, socket}

      validate_config(socket.assigns.config) != :ok ->
        {:noreply, socket}

      true ->
        {:noreply,
         socket
         |> assign(:loading?, true)
         |> assign(:fetch_error, nil)
         |> assign(:activity_progress, nil)
         |> start_fetch_task(socket.assigns.config, false)}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:activity_progress, nil)
     |> assign(:fetch_error, "Background task crashed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info(:workstreams_updated, socket) do
    {:noreply,
     socket
     |> assign(:chart_specs, %{})
     |> assign(:metrics, %{})
     |> put_flash(:info, "Workstream rules updated — re-run fetch to refresh charts")}
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

    task =
      Task.Supervisor.async_nolink(YoutrackWeb.TaskSupervisor, fn ->
        fetch_and_build_specs(config, owner_pid, refresh?)
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

  defp fetch_and_build_specs(config, owner_pid, refresh?) do
    base_url = String.trim(config["base_url"] || "")
    token = String.trim(config["token"] || "")
    base_query = String.trim(config["base_query"] || "")
    days_back = parse_int(config["days_back"], 14)

    state_field = String.trim(config["state_field"] || "State")
    assignees_field = String.trim(config["assignees_field"] || "Assignees")

    in_progress_names = csv_list(config["in_progress_names"])
    done_state_names = csv_list(config["done_state_names"])
    excluded_logins = csv_list(config["excluded_logins"])

    use_activities? = parse_bool(config["use_activities"])
    include_substreams? = parse_bool(config["include_substreams"])

    project_prefix = String.trim(config["project_prefix"] || "")
    unplanned_tag = String.trim(config["unplanned_tag"] || "")
    workstreams_path = String.trim(config["workstreams_path"] || "")

    req = Client.new!(base_url, token)

    today = Date.utc_today() |> Date.to_iso8601()
    start_date = Date.utc_today() |> Date.add(-days_back) |> Date.to_iso8601()
    query = "#{base_query} updated: #{start_date} .. #{today}"

    cache_key = {:flow_metrics_issues, base_url, query}

    {:ok, raw_issues, cache_state} =
      YoutrackWeb.FetchCache.get_or_fetch(
        cache_key,
        fn -> Client.fetch_issues!(req, query) end,
        refresh: refresh?
      )

    issues = filter_by_project_prefix(raw_issues, project_prefix)

    rules = load_rules(workstreams_path)

    {issue_start_at, issue_activities} =
      maybe_fetch_activities(
        req,
        issues,
        use_activities?,
        state_field,
        in_progress_names,
        owner_pid
      )

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

    finished_items = Enum.filter(work_items, &(&1.status == "finished"))
    ongoing_items = Enum.filter(work_items, &(&1.status == "ongoing"))

    cycle_time_data = build_cycle_time_data(finished_items)
    throughput_by_week = build_throughput_by_week(finished_items)
    throughput_by_person = build_throughput_by_person(finished_items)
    wip_by_person = build_wip_by_person(ongoing_items)
    wip_by_stream = build_wip_by_stream(ongoing_items)

    net_active_data =
      build_net_active_data(finished_items, issue_activities, state_field, in_progress_names)

    context_switch_data = build_context_switch_data(work_items, issue_activities, excluded_logins)
    context_switch_avg = build_context_switch_avg(context_switch_data)

    bus_factor_data = build_bus_factor_data(work_items)
    long_running = build_long_running_data(ongoing_items)

    rotation_metrics = Rotation.metrics_by_person(work_items)
    rotation_person_stream = build_rotation_person_stream(work_items)
    rotation_transition_sankey = build_rotation_transition_sankey(work_items)
    stream_tenure = Rotation.stream_tenure(work_items)

    rework_by_stream =
      build_rework_by_stream(work_items, issue_activities, state_field, done_state_names)

    unplanned_items = Enum.filter(work_items, & &1.is_unplanned)
    unplanned_by_stream = build_unplanned_by_stream(unplanned_items)
    unplanned_by_person = build_unplanned_by_person(unplanned_items)
    unplanned_trend = build_unplanned_trend(unplanned_items)

    chart_specs =
      FlowMetricsCharts.build_chart_specs(%{
        throughput_by_week: throughput_by_week,
        throughput_by_person: throughput_by_person,
        cycle_time_data: cycle_time_data,
        net_active_data: net_active_data,
        wip_by_person: wip_by_person,
        wip_by_stream: wip_by_stream,
        context_switch_avg: context_switch_avg,
        context_switch_data: context_switch_data,
        bus_factor_data: bus_factor_data,
        long_running: long_running,
        rotation_metrics: rotation_metrics,
        rotation_person_stream: rotation_person_stream,
        rotation_transition_sankey: rotation_transition_sankey,
        stream_tenure: stream_tenure,
        rework_by_stream: rework_by_stream,
        unplanned_by_stream: unplanned_by_stream,
        unplanned_by_person: unplanned_by_person,
        unplanned_trend: unplanned_trend
      })

    metrics = %{
      total_issues: length(issues),
      total_work_items: length(work_items),
      finished_items: length(finished_items),
      ongoing_items: length(ongoing_items),
      avg_cycle_days: avg_cycle_days(cycle_time_data),
      avg_net_active_days: avg_net_active_days(net_active_data),
      avg_wip_per_person: avg_wip_per_person(wip_by_person),
      avg_context_switch: avg_context_switch(context_switch_avg),
      low_bus_factor_streams: Enum.count(bus_factor_data, &(&1.bus_factor <= 1)),
      reworked_streams: length(rework_by_stream),
      unplanned_issues: unplanned_items |> Enum.uniq_by(& &1.issue_id) |> length()
    }

    {:ok, %{chart_specs: chart_specs, metrics: metrics, fetch_cache_state: cache_state}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp maybe_fetch_activities(_req, _issues, false, _state_field, _in_progress_names, _owner_pid),
    do: {%{}, %{}}

  defp maybe_fetch_activities(req, issues, true, state_field, in_progress_names, owner_pid) do
    total = length(issues)
    send(owner_pid, {:activities_progress, 0, total})

    {data, errors} =
      issues
      |> Task.async_stream(
        fn issue ->
          id = issue["id"]

          case safe_fetch_activities(req, id) do
            {:ok, activities} ->
              start_at = StartAt.from_activities(activities, state_field, in_progress_names)
              {:ok, id, start_at, activities}

            {:error, reason} ->
              {:error, id, reason}
          end
        end,
        ordered: false,
        timeout: :infinity,
        max_concurrency: 8
      )
      |> Enum.reduce({[], [], 0}, fn
        {:ok, {:ok, id, start_at, activities}}, {acc, errors, done} ->
          next_done = done + 1
          send(owner_pid, {:activities_progress, next_done, total})
          {[{id, start_at, activities} | acc], errors, next_done}

        {:ok, {:error, id, reason}}, {acc, errors, done} ->
          next_done = done + 1
          send(owner_pid, {:activities_progress, next_done, total})
          {acc, [{id, reason} | errors], next_done}

        {:exit, reason}, {acc, errors, done} ->
          next_done = done + 1
          send(owner_pid, {:activities_progress, next_done, total})
          {acc, [{"(task)", inspect(reason)} | errors], next_done}
      end)
      |> then(fn {acc, errors, _done} -> {Enum.reverse(acc), errors} end)

    if errors != [] do
      first_reason = errors |> hd() |> elem(1)

      raise "Activities fetch failed for #{length(errors)}/#{total} issues. Sample error: #{first_reason}. Check Base URL/DNS and token."
    end

    issue_start_at =
      Enum.reduce(data, %{}, fn {id, start_at, _}, acc ->
        if is_integer(start_at), do: Map.put(acc, id, start_at), else: acc
      end)

    issue_activities =
      Enum.reduce(data, %{}, fn {id, _start_at, activities}, acc ->
        Map.put(acc, id, activities)
      end)

    {issue_start_at, issue_activities}
  end

  defp safe_fetch_activities(req, issue_id) do
    {:ok, Client.fetch_activities!(req, issue_id)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp filter_by_project_prefix(issues, ""), do: issues

  defp filter_by_project_prefix(issues, prefix) do
    Enum.filter(issues, fn issue ->
      String.starts_with?(issue["idReadable"] || "", prefix)
    end)
  end

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

  defp config_reload_message({:file_change, _paths}),
    do: "Configuration changed on disk and was reloaded"

  defp config_reload_message(:manual), do: "Configuration reloaded"
  defp config_reload_message(_), do: "Configuration updated"

  defp build_throughput_by_week(finished_items) do
    finished_items
    |> Enum.filter(&is_integer(&1.resolved))
    |> Enum.map(fn wi ->
      week =
        wi.resolved
        |> div(1000)
        |> DateTime.from_unix!()
        |> DateTime.to_date()
        |> Date.beginning_of_week(:monday)
        |> Date.to_iso8601()

      %{week: week}
    end)
    |> Enum.frequencies_by(& &1.week)
    |> Enum.map(fn {week, completed} -> %{week: week, completed: completed} end)
    |> Enum.sort_by(& &1.week)
  end

  defp build_throughput_by_person(finished_items) do
    finished_items
    |> Enum.frequencies_by(& &1.person_name)
    |> Enum.map(fn {person, completed} -> %{person: person, completed: completed} end)
    |> Enum.sort_by(& &1.completed, :desc)
  end

  defp build_cycle_time_data(finished_items) do
    finished_items
    |> Enum.filter(&(is_integer(&1.start_at) and is_integer(&1.resolved)))
    |> Enum.map(fn wi ->
      cycle_days = Float.round((wi.resolved - wi.start_at) / 86_400_000, 1)

      %{
        issue_id: wi.issue_id,
        person: wi.person_name,
        stream: wi.stream,
        cycle_days: max(cycle_days, 0.0)
      }
    end)
    |> Enum.uniq_by(& &1.issue_id)
  end

  defp build_net_active_data(_finished_items, issue_activities, _state_field, _in_progress_names)
       when map_size(issue_activities) == 0,
       do: []

  defp build_net_active_data(finished_items, issue_activities, state_field, in_progress_names) do
    finished_items
    |> Enum.filter(&(is_integer(&1.start_at) and is_integer(&1.resolved)))
    |> Enum.uniq_by(& &1.issue_id)
    |> Enum.map(fn wi ->
      activities = Map.get(issue_activities, wi.issue_internal_id, [])

      net_active_ms =
        net_active_ms_for_states(
          activities,
          state_field,
          in_progress_names,
          wi.start_at,
          wi.resolved
        )

      cycle_days = Float.round((wi.resolved - wi.start_at) / 86_400_000, 1)
      net_active_days = Float.round(net_active_ms / 86_400_000, 1)

      %{
        issue_id: wi.issue_id,
        person: wi.person_name,
        stream: wi.stream,
        cycle_days: max(cycle_days, 0.0),
        net_active_days: max(net_active_days, 0.0)
      }
    end)
  end

  defp net_active_ms_for_states(activities, state_field, active_state_names, start_ms, end_ms) do
    hold_tags = ["on hold", "blocked"]

    if function_exported?(WeeklyReport, :net_active_ms_for_states_with_hold, 6) do
      WeeklyReport.net_active_ms_for_states_with_hold(
        activities,
        state_field,
        active_state_names,
        hold_tags,
        start_ms,
        end_ms
      )
    else
      fallback_net_active_ms_for_states_with_hold(
        activities,
        state_field,
        active_state_names,
        hold_tags,
        start_ms,
        end_ms
      )
    end
  end

  defp fallback_net_active_ms_for_states_with_hold(
         _activities,
         _state_field,
         _active_state_names,
         _hold_tags,
         start_ms,
         end_ms
       )
       when not is_integer(start_ms) or not is_integer(end_ms),
       do: 0

  defp fallback_net_active_ms_for_states_with_hold(
         activities,
         state_field,
         active_state_names,
         hold_tags,
         start_ms,
         end_ms
       ) do
    active_set = active_state_names |> Enum.map(&String.downcase/1) |> MapSet.new()

    state_events =
      activities
      |> Enum.filter(fn a -> get_in(a, ["field", "name"]) == state_field end)
      |> Enum.filter(&is_integer(&1["timestamp"]))
      |> Enum.sort_by(& &1["timestamp"])
      |> Enum.filter(fn a -> a["timestamp"] > start_ms and a["timestamp"] <= end_ms end)

    {intervals, active, active_start} =
      Enum.reduce(state_events, {[], true, start_ms}, fn act, {acc, active, active_start} ->
        ts = act["timestamp"]
        to_states = activity_state_names(act)

        entering_active? =
          to_states != [] and Enum.any?(to_states, &(String.downcase(&1) in active_set))

        leaving_active? =
          to_states != [] and Enum.all?(to_states, &(String.downcase(&1) not in active_set))

        cond do
          active and leaving_active? ->
            {[{active_start, ts} | acc], false, nil}

          not active and entering_active? ->
            {acc, true, ts}

          true ->
            {acc, active, active_start}
        end
      end)

    final_intervals =
      if active and is_integer(active_start) do
        [{active_start, end_ms} | intervals]
      else
        intervals
      end

    final_intervals
    |> Enum.filter(fn {s, e} -> e > s end)
    |> then(fn active_intervals ->
      hold_intervals = hold_intervals_from_activities(activities, hold_tags, start_ms, end_ms)
      active_ms = Enum.reduce(active_intervals, 0, fn {s, e}, acc -> acc + (e - s) end)

      paused_ms =
        Enum.reduce(active_intervals, 0, fn {sa, ea}, acc ->
          acc +
            Enum.reduce(hold_intervals, 0, fn {sb, eb}, overlap_acc ->
              overlap_start = max(sa, sb)
              overlap_end = min(ea, eb)
              overlap_acc + max(0, overlap_end - overlap_start)
            end)
        end)

      max(0, active_ms - paused_ms)
    end)
  end

  defp activity_state_names(%{"added" => added}), do: activity_state_names(added)
  defp activity_state_names(%{added: added}), do: activity_state_names(added)

  defp activity_state_names(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      %{name: name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp hold_intervals_from_activities(activities, hold_tags, start_ms, end_ms) do
    hold_set = hold_tags |> Enum.map(&String.downcase/1) |> MapSet.new()

    tag_events =
      activities
      |> Enum.filter(fn a ->
        get_in(a, ["field", "name"]) == "tags" or
          get_in(a, ["category", "id"]) == "TagsCategory"
      end)
      |> Enum.filter(&is_integer(&1["timestamp"]))
      |> Enum.sort_by(& &1["timestamp"])

    active_before_start =
      tag_events
      |> Enum.filter(&(&1["timestamp"] < start_ms))
      |> Enum.reduce(MapSet.new(), fn ev, active ->
        added =
          ev["added"] |> activity_state_names() |> Enum.map(&String.downcase/1) |> MapSet.new()

        removed =
          ev["removed"] |> activity_state_names() |> Enum.map(&String.downcase/1) |> MapSet.new()

        active
        |> MapSet.union(MapSet.intersection(added, hold_set))
        |> MapSet.difference(MapSet.intersection(removed, hold_set))
      end)

    initial_holding? = MapSet.size(active_before_start) > 0

    {active_tags, intervals, hold_start} =
      tag_events
      |> Enum.filter(fn ev -> ev["timestamp"] >= start_ms and ev["timestamp"] <= end_ms end)
      |> Enum.reduce(
        {active_before_start, [], if(initial_holding?, do: start_ms, else: nil)},
        fn ev, {active, acc, current_start} ->
          ts = ev["timestamp"]

          added =
            ev["added"] |> activity_state_names() |> Enum.map(&String.downcase/1) |> MapSet.new()

          removed =
            ev["removed"]
            |> activity_state_names()
            |> Enum.map(&String.downcase/1)
            |> MapSet.new()

          holding_before? = MapSet.size(active) > 0

          next_active =
            active
            |> MapSet.union(MapSet.intersection(added, hold_set))
            |> MapSet.difference(MapSet.intersection(removed, hold_set))

          holding_after? = MapSet.size(next_active) > 0

          cond do
            not holding_before? and holding_after? ->
              {next_active, acc, ts}

            holding_before? and not holding_after? and is_integer(current_start) ->
              {next_active, [{current_start, ts} | acc], nil}

            true ->
              {next_active, acc, current_start}
          end
        end
      )

    intervals =
      if MapSet.size(active_tags) > 0 and is_integer(hold_start) and end_ms > hold_start do
        [{hold_start, end_ms} | intervals]
      else
        intervals
      end

    intervals
    |> Enum.reverse()
    |> Enum.filter(fn {s, e} -> e > s end)
  end

  defp build_wip_by_person(ongoing_items) do
    ongoing_items
    |> Enum.group_by(& &1.person_name)
    |> Enum.map(fn {person, items} ->
      %{person: person, wip: items |> Enum.uniq_by(& &1.issue_id) |> length()}
    end)
    |> Enum.sort_by(& &1.wip, :desc)
  end

  defp build_wip_by_stream(ongoing_items) do
    ongoing_items
    |> Enum.group_by(& &1.stream)
    |> Enum.map(fn {stream, items} ->
      %{stream: stream, wip: items |> Enum.uniq_by(& &1.issue_id) |> length()}
    end)
    |> Enum.sort_by(& &1.wip, :desc)
  end

  defp build_context_switch_data(work_items, _issue_activities, excluded_logins) do
    excluded_set = MapSet.new(excluded_logins)

    # For context switching we want to know: in a given week, how many distinct streams
    # did a person ACTUALLY TOUCH? We use each item's most recent activity timestamp
    # (issue updated, or resolved for finished items) as the single week it counts toward.
    # This reveals genuine week-to-week variation rather than a static "what am I holding".
    work_items
    |> Enum.reject(&MapSet.member?(excluded_set, &1.person_login))
    |> Enum.reduce(%{}, fn wi, acc ->
      # Pick the most meaningful activity timestamp for this item.
      # Prefer resolved (for finished items), then updated, then created.
      ts =
        case wi do
          %{status: "finished", resolved: r} when is_integer(r) -> r
          _ -> Map.get(wi, :updated) || wi.created
        end

      if is_integer(ts) do
        week =
          ts
          |> div(1000)
          |> DateTime.from_unix!()
          |> DateTime.to_date()
          |> Date.beginning_of_week(:monday)
          |> Date.to_iso8601()

        key = {wi.person_name, week}
        streams = Map.get(acc, key, MapSet.new())
        Map.put(acc, key, MapSet.put(streams, wi.stream))
      else
        acc
      end
    end)
    |> Enum.map(fn {{person, week}, streams} ->
      %{person: person, week: week, distinct_streams: MapSet.size(streams)}
    end)
    |> Enum.sort_by(&{&1.week, &1.person})
  end

  defp build_context_switch_avg(context_switch_data) do
    context_switch_data
    |> Enum.group_by(& &1.person)
    |> Enum.map(fn {person, weeks} ->
      avg =
        weeks
        |> Enum.map(& &1.distinct_streams)
        |> average()
        |> Float.round(1)

      %{person: person, avg_streams: avg}
    end)
    |> Enum.sort_by(& &1.avg_streams, :desc)
  end

  defp build_bus_factor_data(work_items) do
    work_items
    |> Enum.group_by(& &1.stream)
    |> Enum.map(fn {stream, items} ->
      unique_people = items |> Enum.map(& &1.person_login) |> Enum.uniq()

      %{
        stream: stream,
        bus_factor: length(unique_people),
        people: Enum.join(unique_people, ", "),
        total_items: items |> Enum.uniq_by(& &1.issue_id) |> length()
      }
    end)
    |> Enum.sort_by(& &1.bus_factor)
  end

  defp build_long_running_data(ongoing_items) do
    now_ms = System.system_time(:millisecond)

    ongoing_items
    |> Enum.filter(&is_integer(&1.start_at))
    |> Enum.map(fn wi ->
      age_days = Float.round((now_ms - wi.start_at) / 86_400_000, 1)

      %{
        issue_id: wi.issue_id,
        person: wi.person_name,
        stream: wi.stream,
        age_days: age_days
      }
    end)
    |> Enum.uniq_by(& &1.issue_id)
    |> Enum.sort_by(& &1.age_days, :desc)
  end

  defp build_rework_by_stream(_work_items, issue_activities, _state_field, _done_state_names)
       when map_size(issue_activities) == 0,
       do: []

  defp build_rework_by_stream(work_items, issue_activities, state_field, done_state_names) do
    rework_counts = Rework.count_by_issue(issue_activities, state_field, done_state_names)

    work_items
    |> Enum.filter(fn wi -> Map.has_key?(rework_counts, wi.issue_internal_id) end)
    |> Enum.uniq_by(& &1.issue_id)
    |> Enum.group_by(& &1.stream)
    |> Enum.map(fn {stream, items} ->
      total_reopenings =
        Enum.sum(Enum.map(items, &Map.get(rework_counts, &1.issue_internal_id, 0)))

      %{stream: stream, rework_issues: length(items), total_reopenings: total_reopenings}
    end)
    |> Enum.sort_by(& &1.rework_issues, :desc)
  end

  defp build_unplanned_by_stream(unplanned_items) do
    unplanned_items
    |> Enum.uniq_by(&{&1.issue_id, &1.stream})
    |> Enum.frequencies_by(& &1.stream)
    |> Enum.map(fn {stream, unplanned} -> %{stream: stream, unplanned: unplanned} end)
    |> Enum.sort_by(& &1.unplanned, :desc)
  end

  defp build_unplanned_by_person(unplanned_items) do
    unplanned_items
    |> Enum.uniq_by(&{&1.issue_id, &1.person_login})
    |> Enum.frequencies_by(& &1.person_name)
    |> Enum.map(fn {person, unplanned} -> %{person: person, unplanned: unplanned} end)
    |> Enum.sort_by(& &1.unplanned, :desc)
  end

  defp build_unplanned_trend(unplanned_items) do
    unplanned_items
    |> Enum.filter(&is_integer(&1.created))
    |> Enum.map(fn wi ->
      week =
        wi.created
        |> div(1000)
        |> DateTime.from_unix!()
        |> DateTime.to_date()
        |> Date.beginning_of_week(:monday)
        |> Date.to_iso8601()

      %{week: week, issue_id: wi.issue_id}
    end)
    |> Enum.uniq_by(&{&1.week, &1.issue_id})
    |> Enum.frequencies_by(& &1.week)
    |> Enum.map(fn {week, unplanned} -> %{week: week, unplanned: unplanned} end)
    |> Enum.sort_by(& &1.week)
  end

  defp build_rotation_person_stream(work_items) do
    work_items
    |> Rotation.person_week_stream()
    |> Enum.sort_by(&{&1.person, &1.stream, &1.week})
  end

  defp build_rotation_transition_sankey(work_items) do
    link_index =
      work_items
      |> Rotation.timeline_by_person()
      |> Enum.flat_map(fn {person, weekly} ->
        weekly
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.flat_map(fn [previous_week, current_week] ->
          if Date.diff(current_week.week, previous_week.week) == 7 do
            build_transition_pairs(person, previous_week.all_streams, current_week.all_streams)
          else
            []
          end
        end)
      end)
      |> Enum.reduce(%{}, fn {source, target, person}, acc ->
        key = {source, target}

        Map.update(acc, key, MapSet.new([person]), fn people ->
          MapSet.put(people, person)
        end)
      end)

    nodes =
      link_index
      |> Map.keys()
      |> Enum.flat_map(fn {source, target} -> [source, target] end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn stream -> %{"name" => stream} end)

    links =
      link_index
      |> Enum.sort_by(fn {{source, target}, _people} -> {source, target} end)
      |> Enum.map(fn {{source, target}, people} ->
        people_list = people |> MapSet.to_list() |> Enum.sort()

        %{
          "source" => source,
          "target" => target,
          "value" => length(people_list),
          "people" => Enum.join(people_list, ", "),
          "people_count" => length(people_list)
        }
      end)

    %{"nodes" => nodes, "links" => links}
  end

  defp build_transition_pairs(person, previous_streams, current_streams) do
    previous_streams
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn source ->
      current_streams
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(&(&1 == source))
      |> Enum.map(fn target -> {source, target, person} end)
    end)
    |> Enum.uniq()
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
      active_section="flow_metrics"
      freshness={@fetch_cache_state}
      topbar_label="Flow Metrics"
      topbar_hint="Cycle time, lead time, and throughput across your boards."
    >
      <div class="space-y-6 pb-10">
        <div class="metrics-card-strong rounded-[2rem] px-6 py-6 sm:px-8">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p class="metrics-eyebrow text-xs uppercase tracking-[0.28em]">Section</p>
              <h2 class="metrics-brand metrics-title mt-2 text-4xl leading-none">Flow Metrics</h2>
              <p class="metrics-copy mt-3">
                Progress, energy, togetherness, autonomy views from the same YouTrack query.
              </p>
            </div>
            <div class="flex gap-2">
              <button
                id="toggle-flow-config"
                type="button"
                phx-click="toggle_config"
                class="metrics-button metrics-button-secondary"
              >
                {if(@config_open?, do: "Hide config", else: "Show config")}
              </button>
              <button
                id="fetch-flow-data"
                type="button"
                phx-click="fetch_data"
                class="metrics-button metrics-button-primary font-semibold"
              >
                Fetch (cache)
              </button>
              <button
                id="fetch-flow-data-refresh"
                type="button"
                phx-click="fetch_data"
                phx-value-refresh="true"
                class="metrics-button metrics-button-secondary"
              >
                Refresh (API)
              </button>
              <button
                id="reload-flow-config"
                type="button"
                phx-click="reload_config"
                class="metrics-button metrics-button-secondary"
              >
                Reload Configuration
              </button>
              <button
                id="clear-flow-cache"
                type="button"
                phx-click="clear_cache"
                class="metrics-button metrics-button-ghost"
              >
                Clear cache
              </button>
            </div>
          </div>
          <%= if @fetch_cache_state do %>
            <p id="flow-cache-state" class="metrics-eyebrow mt-3 text-xs uppercase tracking-[0.2em]">
              Last fetch source: {cache_state_label(@fetch_cache_state)}
            </p>
          <% end %>
        </div>

        <%= if @fetch_error do %>
          <div class="metrics-card rounded-[2rem] border border-red-400/30 bg-red-500/10 p-5 text-red-200">
            {@fetch_error}
          </div>
        <% end %>

        <%= if @loading? or @activity_progress do %>
          <div class="metrics-card metrics-copy rounded-[2rem] p-10 text-center">
            <div class="mx-auto mb-4 h-10 w-10 animate-spin rounded-full border-4 border-stone-700 border-t-orange-400">
            </div>
            <p>Fetching issues, activities, and work-item projections...</p>
            <%= if @activity_progress do %>
              <p id="activities-progress" class="metrics-eyebrow mt-3 text-sm">
                Activities progress: {@activity_progress.done}/{@activity_progress.total}
              </p>
            <% end %>
          </div>
        <% end %>

        <div class="metrics-grid">
          <.stat_card label="Issues" value={metric(@metrics, :total_issues)} tone="neutral" />
          <.stat_card label="Work items" value={metric(@metrics, :total_work_items)} tone="neutral" />
          <.stat_card label="Finished" value={metric(@metrics, :finished_items)} tone="success" />
          <.stat_card label="Ongoing" value={metric(@metrics, :ongoing_items)} tone="warning" />
          <.stat_card
            label="Avg cycle (days)"
            value={metric(@metrics, :avg_cycle_days)}
            tone="accent"
          />
          <%= if @metrics[:avg_net_active_days] do %>
            <.stat_card
              label="Avg net active (days)"
              value={metric(@metrics, :avg_net_active_days)}
              tone="accent"
            />
          <% end %>
          <.stat_card
            label="Context switch"
            value={metric(@metrics, :avg_context_switch)}
            tone="warning"
          />
          <.stat_card
            label="Silo streams"
            value={metric(@metrics, :low_bus_factor_streams)}
            tone="warning"
          />
          <.stat_card
            label="Unplanned issues"
            value={metric(@metrics, :unplanned_issues)}
            tone="accent"
          />
        </div>

        <%= if map_size(@chart_specs) > 0 do %>
          <div
            id="flow-charts-area"
            class="grid gap-6 xl:grid-cols-[15rem_minmax(0,1fr)] xl:items-start"
          >
            <div class="space-y-4 lg:sticky lg:top-6 lg:max-h-[calc(100vh-3rem)] lg:overflow-y-auto">
              <.collapse_controls target="#flow-charts-area" />
              <.chart_toc title="Flow Charts" items={chart_nav_items(@chart_specs)} />
            </div>

            <div class="grid gap-6 md:grid-cols-2">
              <.chart_card
                id="chart-throughput"
                title="Throughput"
                description="Completed items per week."
                spec={@chart_specs.throughput}
                class="h-96"
              />
              <.chart_card
                id="chart-throughput-person"
                title="Throughput by Person"
                spec={@chart_specs.throughput_by_person}
                class="h-96"
              />
              <.collapsible_section
                id="flow-cycle-time-explainer"
                title="Cycle time: project definition"
                subtitle="How this app computes it"
                class="md:col-span-2"
                default_open={false}
              >
                <div class="space-y-2 metrics-copy text-sm leading-relaxed">
                  <p>
                    Cycle time is measured per issue as <strong>resolved_at - start_at</strong>, converted
                    to days.
                  </p>
                  <p>
                    In this project, <strong>start_at</strong> comes from the first transition into an
                    in-progress state when activity data is enabled; otherwise it falls back to issue
                    creation time.
                  </p>
                  <p>
                    Values are deduplicated by issue ID and rounded to one decimal place for
                    visualization.
                  </p>
                </div>
              </.collapsible_section>
              <.chart_card
                id="chart-cycle-hist"
                title="Cycle Time Distribution"
                spec={@chart_specs.cycle_histogram}
                class="h-96"
              />
              <.chart_card
                id="chart-cycle-stream"
                title="Cycle Time by Stream"
                spec={@chart_specs.cycle_by_stream}
                class="h-96"
              />
              <%= if @chart_specs.net_active_histogram do %>
                <.collapsible_section
                  id="flow-net-active-time-explainer"
                  title="Net active time: project definition"
                  subtitle="How this app computes it"
                  class="md:col-span-2"
                  default_open={false}
                >
                  <div class="space-y-2 metrics-copy text-sm leading-relaxed">
                    <p>
                      Net active time is calculated only inside the issue cycle window
                      (<strong>start_at..resolved_at</strong>).
                    </p>
                    <p>
                      The app sums intervals where the state is in one of the configured active
                      states, then subtracts overlap with hold tags.
                    </p>
                    <p>
                      Hold tags are currently <strong>on hold</strong> and <strong>blocked</strong>.
                      The resulting duration is shown in days and rounded to one decimal place.
                    </p>
                  </div>
                </.collapsible_section>
                <.chart_card
                  id="chart-net-active-hist"
                  title="Net Active Time Distribution"
                  spec={@chart_specs.net_active_histogram}
                  class="h-96"
                />
                <.chart_card
                  id="chart-net-active-stream"
                  title="Net Active Time by Stream"
                  spec={@chart_specs.net_active_by_stream}
                  class="h-96"
                />
                <.chart_card
                  id="chart-cycle-vs-net-active"
                  title="Cycle vs Net Active Time"
                  spec={@chart_specs.cycle_vs_net_active}
                  wrapper_class="md:col-span-2"
                />
              <% end %>
              <.chart_card
                id="chart-wip-person"
                title="WIP by Person"
                spec={@chart_specs.wip_by_person}
                class="h-96"
              />
              <.chart_card
                id="chart-wip-stream"
                title="WIP by Stream"
                spec={@chart_specs.wip_by_stream}
                class="h-96"
              />
              <.chart_card
                id="chart-context-avg"
                title="Context Switching Index"
                spec={@chart_specs.context_switch_avg}
                class="h-96"
              />
              <.chart_card
                id="chart-context-heat"
                title="Context Switching Heatmap"
                spec={@chart_specs.context_switch_heatmap}
                wrapper_class="md:col-span-2"
              />
              <.chart_card
                id="chart-bus-factor"
                title="Bus Factor"
                spec={@chart_specs.bus_factor}
                class="h-96"
              />
              <.chart_card
                id="chart-long-running"
                title="Long Running Ongoing Items"
                spec={@chart_specs.long_running}
                class="h-96"
              />
              <.chart_card
                id="chart-rotation-switches"
                title="Rotation Switches"
                spec={@chart_specs.rotation_switches}
                class="h-96"
              />
              <.chart_card
                id="chart-rotation-tenure"
                title="Rotation Tenure"
                spec={@chart_specs.rotation_tenure}
                class="h-96"
              />
              <.chart_card
                id="chart-rotation-person-stream"
                title="Person Timelines by Week"
                description="One panel per teammate. Rows show streams touched each week so parallel work and switching pop out immediately."
                spec={@chart_specs.rotation_person_stream}
                class="min-h-[60rem]"
                wrapper_class="md:col-span-2"
              />
              <.chart_card
                id="chart-rotation-sankey"
                title="Week-to-Week Stream Transition Sankey"
                description="Aggregated transitions across consecutive weeks using all touched streams. Thicker ribbons mean more teammates made that move."
                spec={@chart_specs.rotation_transition_sankey}
                class="h-[34rem]"
                wrapper_class="md:col-span-2 overflow-x-auto"
              />
              <.chart_card
                id="chart-rotation-stream-tenure"
                title="Stream Tenure"
                spec={@chart_specs.rotation_stream_tenure}
                wrapper_class="md:col-span-2"
              />
              <%= if @chart_specs.rework_by_stream do %>
                <.chart_card
                  id="chart-rework-stream"
                  title="Rework by Stream"
                  spec={@chart_specs.rework_by_stream}
                  class="h-96"
                />
              <% end %>
              <.chart_card
                id="chart-unplanned-stream"
                title="Unplanned by Stream"
                spec={@chart_specs.unplanned_by_stream}
                class="h-96"
              />
              <.chart_card
                id="chart-unplanned-person"
                title="Unplanned by Person"
                spec={@chart_specs.unplanned_by_person}
                class="h-96"
              />
              <.chart_card
                id="chart-unplanned-trend"
                title="Unplanned Trend"
                spec={@chart_specs.unplanned_trend}
                class="h-96"
              />
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.dashboard>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:tone, :string, default: "neutral")

  defp stat_card(assigns) do
    ~H"""
    <div class={["rounded-[1.5rem] border px-4 py-4", stat_card_classes(@tone)]}>
      <p class="metrics-stat-label text-xs uppercase tracking-[0.22em]">{@label}</p>
      <p class="metrics-stat-value mt-3 text-xl font-semibold">{@value}</p>
    </div>
    """
  end

  defp stat_card_classes("accent"), do: "metrics-pill-accent"
  defp stat_card_classes("success"), do: "metrics-pill-success"
  defp stat_card_classes("warning"), do: "metrics-button-secondary"
  defp stat_card_classes(_), do: "metrics-pill-muted"

  defp metric(metrics, key) do
    case Map.get(metrics, key) do
      nil -> "-"
      v when is_float(v) -> Float.to_string(v)
      v -> to_string(v)
    end
  end

  defp cache_state_label(:hit), do: "cache hit"
  defp cache_state_label(:miss), do: "cache miss"
  defp cache_state_label(:refresh), do: "refresh"
  defp cache_state_label(%{source: source}), do: cache_state_label(source)
  defp cache_state_label(_), do: "unknown"

  defp chart_nav_items(chart_specs) do
    [
      %{id: "chart-throughput", title: "Throughput"},
      %{id: "chart-throughput-person", title: "Throughput by Person"},
      %{id: "chart-cycle-hist", title: "Cycle Time Distribution"},
      %{id: "chart-cycle-stream", title: "Cycle Time by Stream"},
      %{
        id: "chart-net-active-hist",
        title: "Net Active Time Distribution",
        optional: :net_active_histogram
      },
      %{
        id: "chart-net-active-stream",
        title: "Net Active Time by Stream",
        optional: :net_active_by_stream
      },
      %{
        id: "chart-cycle-vs-net-active",
        title: "Cycle vs Net Active Time",
        optional: :cycle_vs_net_active
      },
      %{id: "chart-wip-person", title: "WIP by Person"},
      %{id: "chart-wip-stream", title: "WIP by Stream"},
      %{id: "chart-context-avg", title: "Context Switching Index"},
      %{id: "chart-context-heat", title: "Context Switching Heatmap"},
      %{id: "chart-bus-factor", title: "Bus Factor"},
      %{id: "chart-long-running", title: "Long Running Ongoing Items"},
      %{id: "chart-rotation-switches", title: "Rotation Switches"},
      %{id: "chart-rotation-tenure", title: "Rotation Tenure"},
      %{id: "chart-rotation-person-stream", title: "Person Timelines by Week"},
      %{id: "chart-rotation-sankey", title: "Week-to-Week Transition Sankey"},
      %{id: "chart-rotation-stream-tenure", title: "Stream Tenure"},
      %{id: "chart-rework-stream", title: "Rework by Stream", optional: :rework_by_stream},
      %{id: "chart-unplanned-stream", title: "Unplanned by Stream"},
      %{id: "chart-unplanned-person", title: "Unplanned by Person"},
      %{id: "chart-unplanned-trend", title: "Unplanned Trend"}
    ]
    |> Enum.filter(fn item ->
      case Map.get(item, :optional) do
        nil -> true
        key -> not is_nil(Map.get(chart_specs, key))
      end
    end)
  end

  defp avg_cycle_days(cycle_time_data) do
    cycle_time_data
    |> Enum.map(& &1.cycle_days)
    |> average()
    |> Float.round(1)
  end

  defp avg_net_active_days([]), do: nil

  defp avg_net_active_days(net_active_data) do
    net_active_data
    |> Enum.map(& &1.net_active_days)
    |> average()
    |> Float.round(1)
  end

  defp avg_wip_per_person(wip_by_person) do
    wip_by_person
    |> Enum.map(& &1.wip)
    |> average()
    |> Float.round(1)
  end

  defp avg_context_switch(context_switch_avg) do
    context_switch_avg
    |> Enum.map(& &1.avg_streams)
    |> average()
    |> Float.round(1)
  end

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / max(length(values), 1)

  defp csv_list(nil), do: []

  defp csv_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_bool(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp parse_bool(_), do: false

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp maybe_nil(""), do: nil
  defp maybe_nil(value), do: value
end
