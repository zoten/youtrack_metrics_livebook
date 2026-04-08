defmodule YoutrackWeb.GanttLive do
  @moduledoc """
  Gantt section with timeline, interrupt analysis, and stream classifier.
  """

  use YoutrackWeb, :live_view

  alias Youtrack.Client
  alias Youtrack.StartAt
  alias Youtrack.WorkItems
  alias Youtrack.Workstreams
  alias Youtrack.WorkstreamsLoader
  alias YoutrackWeb.Configuration
  alias YoutrackWeb.ConfigVisibilityPreference

  @impl true
  def mount(_params, _session, socket) do
    defaults =
      Configuration.defaults()
      |> Configuration.merge_shared(Configuration.shared_from_socket(socket))

    rules = load_rules(defaults["workstreams_path"] || "")
    config_open? = ConfigVisibilityPreference.from_socket(socket)

    socket =
      socket
      |> assign(:current_scope, nil)
      |> assign(:page_title, "Gantt")
      |> assign(:config_open?, config_open?)
      |> assign(:loading?, false)
      |> assign(:fetch_error, nil)
      |> assign(:fetch_cache_state, nil)
      |> assign(:config, defaults)
      |> assign(:config_form, to_form(defaults, as: :config))
      |> assign(:rules, rules)
      |> assign(:chart_specs, %{})
      |> assign(:unclassified_stats, [])
      |> assign(:raw_issues, [])
      |> assign(:work_items_count, 0)

    if connected?(socket) do
      send(self(), :maybe_auto_fetch)
      Phoenix.PubSub.subscribe(YoutrackWeb.PubSub, "workstreams:updated")
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
        rules = load_rules(defaults["workstreams_path"] || "")

        {:noreply,
         socket
         |> assign(:config, defaults)
         |> assign(:config_form, to_form(defaults, as: :config))
         |> assign(:rules, rules)
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
     |> assign(:rules, result.rules)
     |> assign(:chart_specs, result.chart_specs)
     |> assign(:raw_issues, result.raw_issues)
     |> assign(:unclassified_stats, result.unclassified_stats)
     |> assign(:work_items_count, result.work_items_count)
     |> assign(:fetch_cache_state, Map.get(result, :fetch_cache_state))}
  end

  @impl true
  def handle_info({ref, {:error, reason}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:fetch_error, "Gantt fetch failed: #{reason}")}
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
    rules = load_rules(socket.assigns.config["workstreams_path"] || "")

    {:noreply,
     socket
     |> assign(:rules, rules)
     |> assign(:chart_specs, %{})
     |> assign(:raw_issues, [])
     |> assign(:work_items_count, 0)
     |> assign(:unclassified_stats, [])
     |> put_flash(:info, "Workstream rules updated — re-run fetch to refresh charts")}
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
         |> start_fetch_task(socket.assigns.config, false)}
    end
  end

  defp start_fetch_task(socket, config, refresh?) do
    task =
      Task.Supervisor.async_nolink(YoutrackWeb.TaskSupervisor, fn ->
        fetch_and_build_gantt(config, refresh?)
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

  defp fetch_and_build_gantt(config, refresh?) do
    rules = load_rules(config["workstreams_path"] || "")

    base_url = String.trim(config["base_url"] || "")
    token = String.trim(config["token"] || "")
    base_query = String.trim(config["base_query"] || "")
    days_back = parse_int(config["days_back"], 90)

    state_field = String.trim(config["state_field"] || "State")
    assignees_field = String.trim(config["assignees_field"] || "Assignee")

    in_progress_names = csv_list(config["in_progress_names"])
    use_activities? = parse_bool(config["use_activities"])
    include_substreams? = parse_bool(config["include_substreams"])

    project_prefix = String.trim(config["project_prefix"] || "")
    excluded_logins = csv_list(config["excluded_logins"])
    unplanned_tag = String.trim(config["unplanned_tag"] || "")

    today = Date.utc_today() |> Date.to_iso8601()
    start_date = Date.utc_today() |> Date.add(-days_back) |> Date.to_iso8601()
    query = "#{base_query} updated: #{start_date} .. #{today}"

    req = Client.new!(base_url, token)
    cache_key = {:gantt_issues, base_url, query}

    {:ok, raw_issues, cache_state} =
      YoutrackWeb.FetchCache.get_or_fetch(
        cache_key,
        fn -> Client.fetch_issues!(req, query) end,
        refresh: refresh?
      )

    issues = filter_by_project_prefix(raw_issues, project_prefix)

    issue_start_at =
      maybe_fetch_start_at(req, issues, use_activities?, state_field, in_progress_names)

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

    chart_specs = build_chart_specs(work_items)
    unclassified_stats = build_unclassified_stats(issues, rules, include_substreams?)

    {:ok,
     %{
       raw_issues: issues,
       rules: rules,
       chart_specs: chart_specs,
       unclassified_stats: unclassified_stats,
       work_items_count: length(work_items),
       fetch_cache_state: cache_state
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_chart_specs(work_items) do
    unplanned_items = Enum.filter(work_items, & &1.is_unplanned)
    planned_items = Enum.reject(work_items, & &1.is_unplanned)

    pie_data = [
      %{type: "Planned", count: length(planned_items)},
      %{type: "Unplanned", count: length(unplanned_items)}
    ]

    person_stats =
      work_items
      |> Enum.group_by(& &1.person_name)
      |> Enum.map(fn {person, items} ->
        total = length(items)
        unplanned = Enum.count(items, & &1.is_unplanned)
        pct = if total > 0, do: Float.round(unplanned / total * 100, 1), else: 0.0
        %{person: person, total: total, unplanned: unplanned, unplanned_pct: pct}
      end)
      |> Enum.sort_by(& &1.unplanned_pct, :desc)

    stream_stats =
      work_items
      |> Enum.group_by(& &1.stream)
      |> Enum.map(fn {stream, items} ->
        total = length(items)
        unplanned = Enum.count(items, & &1.is_unplanned)
        pct = if total > 0, do: Float.round(unplanned / total * 100, 1), else: 0.0
        %{stream: stream, total: total, unplanned: unplanned, unplanned_pct: pct}
      end)
      |> Enum.sort_by(& &1.unplanned_pct, :desc)

    unplanned_dates =
      unplanned_items
      |> Enum.filter(&is_integer(&1.created))
      |> Enum.map(fn item ->
        date = item.created |> div(1000) |> DateTime.from_unix!() |> DateTime.to_date()
        weekday = Date.day_of_week(date)

        %{
          date: Date.to_iso8601(date),
          weekday_name: weekday_name(weekday),
          monthday: date.day
        }
      end)

    weekday_counts =
      unplanned_dates
      |> Enum.frequencies_by(& &1.weekday_name)
      |> Enum.map(fn {weekday, count} -> %{weekday: weekday, count: count} end)

    monthday_counts =
      unplanned_dates
      |> Enum.frequencies_by(& &1.monthday)
      |> Enum.map(fn {monthday, count} -> %{monthday: monthday, count: count} end)
      |> Enum.sort_by(& &1.monthday)

    unclassified_slug_counts =
      work_items
      |> Enum.filter(&(&1.stream == "(unclassified)"))
      |> Enum.frequencies_by(fn wi ->
        wi.title |> Workstreams.summary_slug() |> Workstreams.canonical_slug()
      end)
      |> Enum.map(fn {slug, count} -> %{slug: slug, count: count} end)
      |> Enum.sort_by(& &1.count, :desc)

    %{
      gantt: gantt_spec(work_items),
      planned_unplanned: planned_unplanned_spec(pie_data),
      unplanned_person: unplanned_by_person_spec(person_stats),
      unplanned_stream: unplanned_by_stream_spec(stream_stats),
      interrupts_weekday: interrupts_weekday_spec(weekday_counts),
      interrupts_monthday: interrupts_monthday_spec(monthday_counts),
      unclassified_slug: unclassified_slug_spec(unclassified_slug_counts)
    }
  end

  defp build_unclassified_stats(issues, rules, include_substreams?) do
    issues
    |> Enum.map(fn issue ->
      streams =
        Workstreams.streams_for_issue(issue, rules, include_substreams: include_substreams?)

      slug =
        issue["summary"]
        |> Workstreams.summary_slug()
        |> Workstreams.normalize_slug()
        |> case do
          nil -> "(no slug)"
          value -> value
        end

      %{
        issue_id: issue["idReadable"] || issue["id"],
        title: issue["summary"],
        slug: slug,
        streams: streams
      }
    end)
    |> Enum.filter(fn row -> row.streams == ["(unclassified)"] end)
    |> Enum.group_by(& &1.slug)
    |> Enum.map(fn {slug, rows} ->
      examples = rows |> Enum.take(3) |> Enum.map(& &1.issue_id)
      %{slug: slug, count: length(rows), examples: examples}
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp load_rules("") do
    {rules, _path} = WorkstreamsLoader.load_from_default_paths()
    rules
  end

  defp load_rules(path) do
    case WorkstreamsLoader.load_file(path) do
      {:ok, rules} -> rules
      {:error, _} -> WorkstreamsLoader.empty_rules()
    end
  end

  defp maybe_fetch_start_at(_req, _issues, false, _state_field, _in_progress_names), do: %{}

  defp maybe_fetch_start_at(req, issues, true, state_field, in_progress_names) do
    {start_at_by_issue, errors} =
      issues
      |> Task.async_stream(
        fn issue ->
          id = issue["id"]

          case safe_fetch_activities(req, id) do
            {:ok, acts} ->
              start_at = StartAt.from_activities(acts, state_field, in_progress_names)
              {:ok, id, start_at}

            {:error, reason} ->
              {:error, id, reason}
          end
        end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.reduce({%{}, []}, fn
        {:ok, {:ok, id, start_at}}, {acc, errors} when is_integer(start_at) ->
          {Map.put(acc, id, start_at), errors}

        {:ok, {:ok, _id, _start_at}}, {acc, errors} ->
          {acc, errors}

        {:ok, {:error, id, reason}}, {acc, errors} ->
          {acc, [{id, reason} | errors]}

        {:exit, reason}, {acc, errors} ->
          {acc, [{"(task)", inspect(reason)} | errors]}
      end)

    if errors == [] do
      start_at_by_issue
    else
      first_reason = errors |> hd() |> elem(1)

      raise "Activities fetch failed for #{length(errors)}/#{length(issues)} issues. Sample error: #{first_reason}. Check Base URL/DNS and token."
    end
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

  defp gantt_spec(work_items) do
    values =
      Enum.map(work_items, fn wi ->
        %{
          issue_id: wi.issue_id,
          title: wi.title,
          person_name: wi.person_name,
          stream: wi.stream,
          status: wi.status,
          work_type: if(wi.is_unplanned, do: "unplanned", else: "planned"),
          start: iso8601_ms(wi.start_at),
          end: iso8601_ms(wi.end_at)
        }
      end)

    stream_count =
      values |> Enum.map(& &1.stream) |> Enum.uniq() |> length() |> max(3)

    row_height = stream_count * 18 + 40

    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "data" => %{"values" => values},
      "facet" => %{
        "row" => %{
          "field" => "person_name",
          "type" => "nominal",
          "header" => %{"title" => nil, "labelFontSize" => 13, "labelPadding" => 8}
        }
      },
      "spec" => %{
        "width" => "container",
        "height" => row_height,
        "mark" => %{"type" => "bar", "tooltip" => true},
        "encoding" => %{
          "x" => %{"field" => "start", "type" => "temporal", "title" => "Time"},
          "x2" => %{"field" => "end"},
          "y" => %{"field" => "stream", "type" => "nominal", "title" => "Stream"},
          "color" => %{
            "field" => "work_type",
            "type" => "nominal",
            "title" => "Work Type",
            "scale" => %{
              "domain" => ["planned", "unplanned"],
              "range" => ["steelblue", "orangered"]
            }
          },
          "opacity" => %{
            "field" => "status",
            "type" => "nominal",
            "title" => "Status",
            "scale" => %{
              "domain" => ["finished", "ongoing", "unfinished"],
              "range" => [0.4, 1.0, 0.7]
            }
          }
        }
      }
    }
  end

  defp planned_unplanned_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Planned vs Unplanned Work",
      "width" => 320,
      "height" => 320,
      "data" => %{"values" => values},
      "mark" => %{"type" => "arc", "tooltip" => true},
      "encoding" => %{
        "theta" => %{"field" => "count", "type" => "quantitative"},
        "color" => %{
          "field" => "type",
          "type" => "nominal",
          "scale" => %{
            "domain" => ["Planned", "Unplanned"],
            "range" => ["steelblue", "orangered"]
          }
        }
      }
    }
  end

  defp unplanned_by_person_spec(values),
    do: person_bar(values, "Unplanned Work % by Person", "unplanned_pct", "Unplanned %")

  defp unplanned_by_stream_spec(values),
    do: stream_bar(values, "Unplanned Work % by Workstream", "unplanned_pct", "Unplanned %")

  defp interrupts_weekday_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Interrupts by Day of Week",
      "width" => 420,
      "height" => 200,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true, "color" => "orangered"},
      "encoding" => %{
        "x" => %{
          "field" => "weekday",
          "type" => "ordinal",
          "sort" => ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
          "title" => "Day"
        },
        "y" => %{"field" => "count", "type" => "quantitative", "title" => "Interrupt Count"}
      }
    }
  end

  defp interrupts_monthday_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Interrupts by Day of Month",
      "width" => 620,
      "height" => 200,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true, "color" => "orangered"},
      "encoding" => %{
        "x" => %{"field" => "monthday", "type" => "ordinal", "title" => "Day of Month"},
        "y" => %{"field" => "count", "type" => "quantitative", "title" => "Interrupt Count"}
      }
    }
  end

  defp unclassified_slug_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Unclassified Slugs",
      "width" => 600,
      "height" => 280,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true, "color" => "#f97352"},
      "encoding" => %{
        "x" => %{"field" => "slug", "type" => "nominal", "title" => "Slug", "sort" => "-y"},
        "y" => %{"field" => "count", "type" => "quantitative", "title" => "Issues"}
      }
    }
  end

  defp person_bar(values, title, y_field, y_title) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "person", "type" => "nominal", "title" => "Person", "sort" => "-y"},
        "y" => %{"field" => y_field, "type" => "quantitative", "title" => y_title},
        "color" => %{
          "field" => y_field,
          "type" => "quantitative",
          "scale" => %{"scheme" => "oranges"}
        }
      }
    }
  end

  defp stream_bar(values, title, y_field, y_title) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "stream", "type" => "nominal", "title" => "Stream", "sort" => "-y"},
        "y" => %{"field" => y_field, "type" => "quantitative", "title" => y_title},
        "color" => %{
          "field" => y_field,
          "type" => "quantitative",
          "scale" => %{"scheme" => "oranges"}
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
      config_form={@config_form}
      config_open?={@config_open?}
      active_section="gantt"
      freshness={@fetch_cache_state}
      topbar_label="Gantt"
      topbar_hint="Timeline view of work items and workstream classification."
    >
      <div class="space-y-6 pb-10">
        <div class="metrics-card-strong rounded-[2rem] px-6 py-6 sm:px-8">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p class="metrics-eyebrow text-xs uppercase tracking-[0.28em]">Section</p>
              <h2 class="metrics-brand metrics-title mt-2 text-4xl leading-none">Gantt</h2>
              <p class="metrics-copy mt-3">
                Timelines, interrupts, and interactive stream classification.
              </p>
            </div>
            <div class="flex gap-2">
              <button
                id="toggle-gantt-config"
                type="button"
                phx-click="toggle_config"
                class="metrics-button metrics-button-secondary"
              >
                {if(@config_open?, do: "Hide config", else: "Show config")}
              </button>
              <button
                id="fetch-gantt-data"
                type="button"
                phx-click="fetch_data"
                class="metrics-button metrics-button-primary font-semibold"
              >
                Fetch (cache)
              </button>
              <button
                id="fetch-gantt-data-refresh"
                type="button"
                phx-click="fetch_data"
                phx-value-refresh="true"
                class="metrics-button metrics-button-secondary"
              >
                Refresh (API)
              </button>
              <button
                id="reload-gantt-config"
                type="button"
                phx-click="reload_config"
                class="metrics-button metrics-button-secondary"
              >
                Reload Configuration
              </button>
              <button
                id="clear-gantt-cache"
                type="button"
                phx-click="clear_cache"
                class="metrics-button metrics-button-ghost"
              >
                Clear cache
              </button>
            </div>
          </div>
          <%= if @fetch_cache_state do %>
            <p id="gantt-cache-state" class="metrics-eyebrow mt-3 text-xs uppercase tracking-[0.2em]">
              Last fetch source: {cache_state_label(@fetch_cache_state)}
            </p>
          <% end %>
        </div>

        <%= if @fetch_error do %>
          <div class="metrics-card rounded-[2rem] border border-red-400/30 bg-red-500/10 p-5 text-red-200">
            {@fetch_error}
          </div>
        <% end %>

        <p class="metrics-copy text-xs">
          Edit workstream classification rules on the
          <.link navigate="/workstreams" class="underline text-[color:var(--metrics-accent)]">
            Workstream Config
          </.link>
          page.
        </p>

        <%= if @loading? do %>
          <div class="metrics-card metrics-copy rounded-[2rem] p-10 text-center">
            <div class="metrics-spinner mx-auto mb-4 h-10 w-10 animate-spin rounded-full border-4">
            </div>
            Fetching and building gantt data...
          </div>
        <% end %>

        <div class="metrics-grid">
          <.stat_card label="Filtered issues" value={to_string(length(@raw_issues))} tone="neutral" />
          <.stat_card label="Work items" value={to_string(@work_items_count)} tone="success" />
          <.stat_card
            label="Unclassified slugs"
            value={to_string(length(@unclassified_stats))}
            tone="warning"
          />
        </div>

        <%= if @unclassified_stats != [] do %>
          <section id="gantt-unclassified-examples" class="metrics-card rounded-[2rem] p-6">
            <h3 class="metrics-title text-lg font-semibold">Unclassified examples</h3>
            <p class="metrics-copy mt-2 text-sm leading-6">
              Open these cards directly to classify patterns and tags faster.
            </p>
            <div class="mt-4 overflow-x-auto">
              <table class="metrics-table min-w-full text-sm">
                <thead>
                  <tr class="border-b">
                    <th class="px-3 py-2 text-left">Slug</th>
                    <th class="px-3 py-2 text-left">Count</th>
                    <th class="px-3 py-2 text-left">Examples</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for row <- @unclassified_stats do %>
                    <tr class="border-b">
                      <td class="px-3 py-2">{row.slug}</td>
                      <td class="px-3 py-2">{row.count}</td>
                      <td class="px-3 py-2">
                        <div class="flex flex-wrap gap-2">
                          <%= for issue_id <- row.examples do %>
                            <.link
                              id={"gantt-unclassified-card-#{issue_id}"}
                              navigate={~p"/card/#{issue_id}"}
                              class="metrics-pill metrics-pill-accent px-2 py-1 text-[11px]"
                            >
                              {issue_id}
                            </.link>
                          <% end %>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <%= if map_size(@chart_specs) > 0 do %>
          <div
            id="gantt-charts-area"
            class="grid gap-6 xl:grid-cols-[15rem_minmax(0,1fr)] xl:items-start"
          >
            <div class="space-y-4 lg:sticky lg:top-6 lg:max-h-[calc(100vh-3rem)] lg:overflow-y-auto">
              <.collapse_controls target="#gantt-charts-area" />
              <.chart_toc title="Gantt Charts" items={chart_nav_items()} />
            </div>

            <div class="grid gap-6 md:grid-cols-2">
              <.chart_card
                id="gantt-main-chart"
                title="Team Gantt"
                spec={@chart_specs.gantt}
                wrapper_class="md:col-span-2"
                class="min-h-[24rem]"
              />
              <.chart_card
                id="gantt-planned-unplanned-chart"
                title="Planned vs Unplanned"
                spec={@chart_specs.planned_unplanned}
                class="h-96"
              />
              <.chart_card
                id="gantt-unplanned-person-chart"
                title="Unplanned by Person"
                spec={@chart_specs.unplanned_person}
                class="h-96"
              />
              <.chart_card
                id="gantt-unplanned-stream-chart"
                title="Unplanned by Workstream"
                spec={@chart_specs.unplanned_stream}
                class="h-96"
              />
              <.chart_card
                id="gantt-interrupts-weekday-chart"
                title="Interrupts by Weekday"
                spec={@chart_specs.interrupts_weekday}
                class="h-80"
              />
              <.chart_card
                id="gantt-interrupts-monthday-chart"
                title="Interrupts by Monthday"
                spec={@chart_specs.interrupts_monthday}
                class="h-80"
              />
              <.chart_card
                id="gantt-unclassified-slug-chart"
                title="Unclassified Slugs"
                spec={@chart_specs.unclassified_slug}
                class="h-80"
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

  defp cache_state_label(:hit), do: "cache hit"
  defp cache_state_label(:miss), do: "cache miss"
  defp cache_state_label(:refresh), do: "refresh"
  defp cache_state_label(%{source: source}), do: cache_state_label(source)
  defp cache_state_label(_), do: "unknown"

  defp chart_nav_items do
    [
      %{id: "gantt-main-chart", title: "Team Gantt"},
      %{id: "gantt-planned-unplanned-chart", title: "Planned vs Unplanned"},
      %{id: "gantt-unplanned-person-chart", title: "Unplanned by Person"},
      %{id: "gantt-unplanned-stream-chart", title: "Unplanned by Workstream"},
      %{id: "gantt-interrupts-weekday-chart", title: "Interrupts by Weekday"},
      %{id: "gantt-interrupts-monthday-chart", title: "Interrupts by Monthday"},
      %{id: "gantt-unclassified-slug-chart", title: "Unclassified Slugs"}
    ]
  end

  defp iso8601_ms(ms) when is_integer(ms) do
    ms |> div(1000) |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end

  defp weekday_name(1), do: "Mon"
  defp weekday_name(2), do: "Tue"
  defp weekday_name(3), do: "Wed"
  defp weekday_name(4), do: "Thu"
  defp weekday_name(5), do: "Fri"
  defp weekday_name(6), do: "Sat"
  defp weekday_name(7), do: "Sun"

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
