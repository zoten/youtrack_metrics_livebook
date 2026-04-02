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
  alias Youtrack.WorkItems
  alias Youtrack.WorkstreamsLoader
  alias YoutrackWeb.Configuration
  alias YoutrackWeb.ConfigVisibilityPreference

  @impl true
  def mount(_params, _session, socket) do
    defaults = Configuration.defaults()
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

    if connected?(socket), do: send(self(), :maybe_auto_fetch)

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
    {:noreply,
     socket
     |> assign(:config, params)
     |> assign(:config_form, to_form(params, as: :config))}
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

    context_switch_data = build_context_switch_data(work_items)
    context_switch_avg = build_context_switch_avg(context_switch_data)

    bus_factor_data = build_bus_factor_data(work_items)
    long_running = build_long_running_data(ongoing_items)

    rotation_metrics = Rotation.metrics_by_person(work_items)
    rotation_person_stream = Rotation.person_week_stream(work_items)
    stream_tenure = Rotation.stream_tenure(work_items)

    rework_by_stream =
      build_rework_by_stream(work_items, issue_activities, state_field, done_state_names)

    unplanned_items = Enum.filter(work_items, & &1.is_unplanned)
    unplanned_by_stream = build_unplanned_by_stream(unplanned_items)
    unplanned_by_person = build_unplanned_by_person(unplanned_items)
    unplanned_trend = build_unplanned_trend(unplanned_items)

    chart_specs = %{
      throughput: throughput_spec(throughput_by_week),
      throughput_by_person: throughput_by_person_spec(throughput_by_person),
      cycle_histogram: cycle_histogram_spec(cycle_time_data),
      cycle_by_stream: cycle_by_stream_spec(cycle_time_data),
      wip_by_person: wip_by_person_spec(wip_by_person),
      wip_by_stream: wip_by_stream_spec(wip_by_stream),
      context_switch_avg: context_switch_avg_spec(context_switch_avg),
      context_switch_heatmap: context_switch_heatmap_spec(context_switch_data),
      bus_factor: bus_factor_spec(bus_factor_data),
      long_running: long_running_spec(long_running),
      rotation_switches: rotation_switches_spec(rotation_metrics),
      rotation_tenure: rotation_tenure_spec(rotation_metrics),
      rotation_person_stream: rotation_person_stream_spec(rotation_person_stream),
      rotation_stream_tenure: rotation_stream_tenure_spec(stream_tenure),
      rework_by_stream:
        if(rework_by_stream == [], do: nil, else: rework_by_stream_spec(rework_by_stream)),
      unplanned_by_stream: unplanned_by_stream_spec(unplanned_by_stream),
      unplanned_by_person: unplanned_by_person_spec(unplanned_by_person),
      unplanned_trend: unplanned_trend_spec(unplanned_trend)
    }

    metrics = %{
      total_issues: length(issues),
      total_work_items: length(work_items),
      finished_items: length(finished_items),
      ongoing_items: length(ongoing_items),
      avg_cycle_days: avg_cycle_days(cycle_time_data),
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

    data =
      issues
      |> Task.async_stream(
        fn issue ->
          id = issue["id"]
          activities = Client.fetch_activities!(req, id)
          start_at = StartAt.from_activities(activities, state_field, in_progress_names)
          {id, start_at, activities}
        end,
        ordered: false,
        timeout: :infinity,
        max_concurrency: 8
      )
      |> Enum.reduce({[], 0}, fn
        {:ok, item}, {acc, done} ->
          next_done = done + 1
          send(owner_pid, {:activities_progress, next_done, total})
          {[item | acc], next_done}

        _other, {acc, done} ->
          next_done = done + 1
          send(owner_pid, {:activities_progress, next_done, total})
          {acc, next_done}
      end)
      |> elem(0)
      |> Enum.reverse()

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

  defp filter_by_project_prefix(issues, ""), do: issues

  defp filter_by_project_prefix(issues, prefix) do
    Enum.filter(issues, fn issue ->
      String.starts_with?(issue["idReadable"] || "", prefix)
    end)
  end

  defp load_rules("") do
    {rules, _path} = WorkstreamsLoader.load_from_default_paths()
    rules
  end

  defp load_rules(path) do
    case WorkstreamsLoader.load_file(path) do
      {:ok, rules} -> rules
      {:error, _reason} -> WorkstreamsLoader.empty_rules()
    end
  end

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

  defp build_context_switch_data(work_items) do
    work_items
    |> Enum.filter(&is_integer(&1.created))
    |> Enum.map(fn wi ->
      week =
        wi.created
        |> div(1000)
        |> DateTime.from_unix!()
        |> DateTime.to_date()
        |> Date.beginning_of_week(:monday)
        |> Date.to_iso8601()

      %{person: wi.person_name, week: week, stream: wi.stream}
    end)
    |> Enum.group_by(&{&1.person, &1.week})
    |> Enum.map(fn {{person, week}, items} ->
      distinct_streams = items |> Enum.map(& &1.stream) |> Enum.uniq() |> length()
      %{person: person, week: week, distinct_streams: distinct_streams}
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

  @spec throughput_spec(list(map())) :: map()
  defp throughput_spec(values),
    do:
      layered_time_chart(values, "Throughput: Completed Items per Week", "completed", "Completed")

  defp throughput_by_person_spec(values),
    do: person_bar(values, "Throughput by Person", "completed", "Completed", "steelblue")

  defp cycle_histogram_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Cycle Time Distribution (days)",
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{
          "field" => "cycle_days",
          "type" => "quantitative",
          "bin" => %{"maxbins" => 20},
          "title" => "Cycle Time (days)"
        },
        "y" => %{"aggregate" => "count", "type" => "quantitative", "title" => "Count"}
      }
    }
  end

  defp cycle_by_stream_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Cycle Time by Workstream",
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "boxplot", "extent" => 1.5},
      "encoding" => %{
        "x" => %{
          "field" => "stream",
          "type" => "nominal",
          "title" => "Workstream",
          "sort" => "ascending"
        },
        "y" => %{
          "field" => "cycle_days",
          "type" => "quantitative",
          "title" => "Cycle Time (days)"
        },
        "color" => %{"field" => "stream", "type" => "nominal", "legend" => nil}
      }
    }
  end

  defp wip_by_person_spec(values),
    do: person_bar(values, "Current WIP per Person", "wip", "Active Items", nil)

  defp wip_by_stream_spec(values),
    do: stream_bar(values, "Current WIP by Workstream", "wip", "Active Items", "teal")

  defp context_switch_avg_spec(values),
    do:
      person_bar(
        values,
        "Avg Context Switching Index per Person",
        "avg_streams",
        "Avg Distinct Streams/Week",
        nil
      )

  defp context_switch_heatmap_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Context Switching: Streams per Person per Week",
      "width" => 700,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "rect", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
        "y" => %{
          "field" => "person",
          "type" => "nominal",
          "title" => "Person",
          "sort" => "ascending"
        },
        "color" => %{
          "field" => "distinct_streams",
          "type" => "quantitative",
          "title" => "Distinct Streams",
          "scale" => %{"scheme" => "oranges"}
        }
      }
    }
  end

  defp bus_factor_spec(values),
    do: stream_bar(values, "Bus Factor by Workstream", "bus_factor", "Unique Contributors", nil)

  defp long_running_spec(values), do: issue_age_bar(values, "Ongoing Items by Age (days)")

  defp rotation_switches_spec(values),
    do: person_bar(values, "Stream Switches per Person", "switches", "Stream Switches", nil)

  defp rotation_tenure_spec(values),
    do:
      person_bar(
        values,
        "Average Tenure per Stream (weeks)",
        "avg_tenure_weeks",
        "Avg Weeks on Same Stream",
        "mediumpurple"
      )

  defp rotation_person_stream_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Person × Week: Workstream Activity",
      "width" => 700,
      "height" => 400,
      "data" => %{"values" => values},
      "mark" => %{"type" => "rect", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
        "y" => %{"field" => "person", "type" => "nominal", "title" => "Person"},
        "color" => %{"field" => "stream", "type" => "nominal", "title" => "Workstream"}
      }
    }
  end

  defp rotation_stream_tenure_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Stream Tenure: Total Weeks per Person per Stream",
      "width" => 700,
      "height" => 400,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "person", "type" => "nominal", "title" => "Person"},
        "y" => %{
          "field" => "total_weeks",
          "type" => "quantitative",
          "title" => "Total Weeks",
          "stack" => "zero"
        },
        "color" => %{"field" => "stream", "type" => "nominal", "title" => "Workstream"}
      }
    }
  end

  defp rework_by_stream_spec(values),
    do: stream_bar(values, "Rework by Workstream", "rework_issues", "Reworked Issues", "coral")

  defp unplanned_by_stream_spec(values),
    do:
      stream_bar(
        values,
        "Unplanned Work by Workstream",
        "unplanned",
        "Unplanned Issues",
        "salmon"
      )

  defp unplanned_by_person_spec(values),
    do:
      person_bar(
        values,
        "Unplanned Work by Person",
        "unplanned",
        "Unplanned Issues",
        "darkorange"
      )

  defp unplanned_trend_spec(values),
    do:
      layered_time_chart(
        values,
        "Unplanned Work Trend (per week)",
        "unplanned",
        "Unplanned Issues"
      )

  defp layered_time_chart(values, title, field, y_title) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "width" => 700,
      "height" => 300,
      "data" => %{"values" => values},
      "layer" => [
        %{
          "mark" => %{"type" => "bar", "opacity" => 0.5, "color" => "salmon"},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
            "y" => %{"field" => field, "type" => "quantitative", "title" => y_title}
          }
        },
        %{
          "mark" => %{"type" => "line", "color" => "red", "point" => true},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal"},
            "y" => %{"field" => field, "type" => "quantitative"}
          }
        }
      ]
    }
  end

  defp person_bar(values, title, field, x_title, color) do
    mark =
      if color,
        do: %{"type" => "bar", "tooltip" => true, "color" => color},
        else: %{"type" => "bar", "tooltip" => true}

    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => mark,
      "encoding" => %{
        "x" => %{"field" => "person", "type" => "nominal", "title" => "Person", "sort" => "-y"},
        "y" => %{"field" => field, "type" => "quantitative", "title" => x_title}
      }
    }
  end

  defp stream_bar(values, title, field, y_title, color) do
    mark =
      if color,
        do: %{"type" => "bar", "tooltip" => true, "color" => color},
        else: %{"type" => "bar", "tooltip" => true}

    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => mark,
      "encoding" => %{
        "x" => %{
          "field" => "stream",
          "type" => "nominal",
          "title" => "Workstream",
          "sort" => "-y"
        },
        "y" => %{"field" => field, "type" => "quantitative", "title" => y_title}
      }
    }
  end

  defp issue_age_bar(values, title) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "width" => 700,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "issue_id", "type" => "nominal", "title" => "Issue", "sort" => "-y"},
        "y" => %{"field" => "age_days", "type" => "quantitative", "title" => "Age (days)"},
        "color" => %{
          "field" => "age_days",
          "type" => "quantitative",
          "scale" => %{"scheme" => "orangered"}
        }
      }
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_scope}
      config={@config}
      active_section="flow_metrics"
      freshness={@fetch_cache_state}
      topbar_label="Live view"
      topbar_hint="Switch theme once here; the same preference follows every metrics route."
    >
      <div class="space-y-6 pb-10">
          <div class="metrics-card-strong rounded-[2rem] px-6 py-6 sm:px-8">
            <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <p class="metrics-eyebrow text-xs uppercase tracking-[0.28em]">Section</p>
                <h2 class="metrics-brand metrics-title mt-2 text-4xl leading-none">Flow Metrics</h2>
                <p class="metrics-copy mt-3">Progress, energy, togetherness, autonomy views from the same YouTrack query.</p>
              </div>
              <div class="flex gap-2">
                <button id="toggle-flow-config" type="button" phx-click="toggle_config" class="metrics-button metrics-button-secondary">
                  {if(@config_open?, do: "Hide config", else: "Show config")}
                </button>
                <button id="fetch-flow-data" type="button" phx-click="fetch_data" class="metrics-button metrics-button-primary font-semibold">
                  Fetch (cache)
                </button>
                <button id="fetch-flow-data-refresh" type="button" phx-click="fetch_data" phx-value-refresh="true" class="metrics-button metrics-button-secondary">
                  Refresh (API)
                </button>
                <button id="clear-flow-cache" type="button" phx-click="clear_cache" class="metrics-button metrics-button-ghost">
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
            <div class="metrics-card rounded-[2rem] border border-red-400/30 bg-red-500/10 p-5 text-red-200">{@fetch_error}</div>
          <% end %>

          <%= if @config_open? do %>
            <section class="metrics-card rounded-[2rem] p-6">
              <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Configuration</p>
              <.form for={@config_form} id="flow-config-form" phx-change="config_changed" class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
                <.input field={@config_form[:base_url]} type="text" label="Base URL" />
                <.input field={@config_form[:token]} type="password" label="Token" />
                <.input field={@config_form[:base_query]} type="text" label="Base query" />
                <.input field={@config_form[:project_prefix]} type="text" label="Project prefix" />
                <.input field={@config_form[:days_back]} type="number" label="Days back" />
                <.input field={@config_form[:state_field]} type="text" label="State field" />
                <.input field={@config_form[:assignees_field]} type="text" label="Assignees field" />
                <.input field={@config_form[:in_progress_names]} type="text" label="In-progress states (CSV)" />
                <.input field={@config_form[:done_state_names]} type="text" label="Done states (CSV)" />
                <.input field={@config_form[:excluded_logins]} type="text" label="Excluded logins (CSV)" />
                <.input field={@config_form[:unplanned_tag]} type="text" label="Unplanned tag" />
                <.input field={@config_form[:workstreams_path]} type="text" label="Workstreams path" />
                <.input field={@config_form[:use_activities]} type="select" label="Use activities" options={[{"Yes", "true"}, {"No", "false"}]} />
                <.input field={@config_form[:include_substreams]} type="select" label="Include substreams" options={[{"Yes", "true"}, {"No", "false"}]} />
              </.form>
            </section>
          <% end %>

          <%= if @loading? or @activity_progress do %>
            <div class="metrics-card metrics-copy rounded-[2rem] p-10 text-center">
              <div class="mx-auto mb-4 h-10 w-10 animate-spin rounded-full border-4 border-stone-700 border-t-orange-400"></div>
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
            <.stat_card label="Avg cycle (days)" value={metric(@metrics, :avg_cycle_days)} tone="accent" />
            <.stat_card label="Context switch" value={metric(@metrics, :avg_context_switch)} tone="warning" />
            <.stat_card label="Silo streams" value={metric(@metrics, :low_bus_factor_streams)} tone="warning" />
            <.stat_card label="Unplanned issues" value={metric(@metrics, :unplanned_issues)} tone="accent" />
          </div>

          <%= if map_size(@chart_specs) > 0 do %>
            <div class="grid gap-6 xl:grid-cols-[15rem_minmax(0,1fr)] xl:items-start">
              <.chart_toc title="Flow Charts" items={chart_nav_items(@chart_specs)} />

              <div class="grid gap-6 md:grid-cols-2">
                <.chart_card id="chart-throughput" title="Throughput" description="Completed items per week." spec={@chart_specs.throughput} class="h-96" />
                <.chart_card id="chart-throughput-person" title="Throughput by Person" spec={@chart_specs.throughput_by_person} class="h-96" />
                <.chart_card id="chart-cycle-hist" title="Cycle Time Distribution" spec={@chart_specs.cycle_histogram} class="h-96" />
                <.chart_card id="chart-cycle-stream" title="Cycle Time by Stream" spec={@chart_specs.cycle_by_stream} class="h-96" />
                <.chart_card id="chart-wip-person" title="WIP by Person" spec={@chart_specs.wip_by_person} class="h-96" />
                <.chart_card id="chart-wip-stream" title="WIP by Stream" spec={@chart_specs.wip_by_stream} class="h-96" />
                <.chart_card id="chart-context-avg" title="Context Switching Index" spec={@chart_specs.context_switch_avg} class="h-96" />
                <.chart_card id="chart-context-heat" title="Context Switching Heatmap" spec={@chart_specs.context_switch_heatmap} wrapper_class="md:col-span-2" />
                <.chart_card id="chart-bus-factor" title="Bus Factor" spec={@chart_specs.bus_factor} class="h-96" />
                <.chart_card id="chart-long-running" title="Long Running Ongoing Items" spec={@chart_specs.long_running} class="h-96" />
                <.chart_card id="chart-rotation-switches" title="Rotation Switches" spec={@chart_specs.rotation_switches} class="h-96" />
                <.chart_card id="chart-rotation-tenure" title="Rotation Tenure" spec={@chart_specs.rotation_tenure} class="h-96" />
                <.chart_card id="chart-rotation-person-stream" title="Person × Week Activity" spec={@chart_specs.rotation_person_stream} wrapper_class="md:col-span-2" />
                <.chart_card id="chart-rotation-stream-tenure" title="Stream Tenure" spec={@chart_specs.rotation_stream_tenure} wrapper_class="md:col-span-2" />
                <%= if @chart_specs.rework_by_stream do %>
                  <.chart_card id="chart-rework-stream" title="Rework by Stream" spec={@chart_specs.rework_by_stream} class="h-96" />
                <% end %>
                <.chart_card id="chart-unplanned-stream" title="Unplanned by Stream" spec={@chart_specs.unplanned_by_stream} class="h-96" />
                <.chart_card id="chart-unplanned-person" title="Unplanned by Person" spec={@chart_specs.unplanned_by_person} class="h-96" />
                <.chart_card id="chart-unplanned-trend" title="Unplanned Trend" spec={@chart_specs.unplanned_trend} class="h-96" />
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
      %{id: "chart-wip-person", title: "WIP by Person"},
      %{id: "chart-wip-stream", title: "WIP by Stream"},
      %{id: "chart-context-avg", title: "Context Switching Index"},
      %{id: "chart-context-heat", title: "Context Switching Heatmap"},
      %{id: "chart-bus-factor", title: "Bus Factor"},
      %{id: "chart-long-running", title: "Long Running Ongoing Items"},
      %{id: "chart-rotation-switches", title: "Rotation Switches"},
      %{id: "chart-rotation-tenure", title: "Rotation Tenure"},
      %{id: "chart-rotation-person-stream", title: "Person × Week Activity"},
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
