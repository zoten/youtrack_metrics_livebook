defmodule YoutrackWeb.PairingLive do
  @moduledoc """
  Pairing section with collaboration, firefighter, and interrupt analytics.
  """

  use YoutrackWeb, :live_view

  alias Youtrack.Client
  alias Youtrack.PairingAnalysis
  alias Youtrack.WorkstreamsLoader
  alias YoutrackWeb.Configuration

  @impl true
  def mount(_params, _session, socket) do
    defaults = Configuration.defaults()

    socket =
      socket
      |> assign(:current_scope, nil)
      |> assign(:page_title, "Pairing")
      |> assign(:config_open?, true)
      |> assign(:loading?, false)
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
    {:noreply, update(socket, :config_open?, &(!&1))}
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
  def handle_info({ref, {:ok, result}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:loading?, false)
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
     |> assign(:fetch_error, "Pairing fetch failed: #{reason}")}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:fetch_error, "Background task crashed: #{inspect(reason)}")}
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
        fetch_and_build_pairing(config, refresh?)
      end)

    assign(socket, :fetch_task_ref, task.ref)
  end

  defp fetch_and_build_pairing(config, refresh?) do
    base_url = String.trim(config["base_url"] || "")
    token = String.trim(config["token"] || "")
    base_query = String.trim(config["base_query"] || "")
    days_back = parse_int(config["days_back"], 90)

    assignees_field = String.trim(config["assignees_field"] || "Assignee")
    project_prefix = String.trim(config["project_prefix"] || "")
    excluded_logins = csv_list(config["excluded_logins"])
    include_substreams? = parse_bool(config["include_substreams"])
    unplanned_tag = String.trim(config["unplanned_tag"] || "")

    rules = load_rules(config["workstreams_path"] || "")

    today = Date.utc_today() |> Date.to_iso8601()
    start_date = Date.utc_today() |> Date.add(-days_back) |> Date.to_iso8601()
    query = "#{base_query} updated: #{start_date} .. #{today}"

    req = Client.new!(base_url, token)
    cache_key = {:pairing_issues, base_url, query}

    {:ok, raw_issues, cache_state} =
      YoutrackWeb.FetchCache.get_or_fetch(
        cache_key,
        fn -> Client.fetch_issues!(req, query) end,
        refresh: refresh?
      )

    issues = filter_by_project_prefix(raw_issues, project_prefix)

    pair_records =
      PairingAnalysis.extract_pairs(
        issues,
        assignees_field: assignees_field,
        excluded_logins: excluded_logins,
        workstream_rules: rules,
        include_substreams: include_substreams?,
        unplanned_tag: maybe_nil(unplanned_tag)
      )

    chart_specs = build_chart_specs(pair_records)

    paired_issues = pair_records |> Enum.map(& &1.issue_id) |> Enum.uniq() |> length()
    unplanned_pairs = Enum.count(pair_records, & &1.is_unplanned)

    metrics = %{
      total_issues: length(issues),
      paired_issues: paired_issues,
      paired_issues_pct: pct(paired_issues, length(issues)),
      pair_occurrences: length(pair_records),
      unplanned_pairs: unplanned_pairs,
      unplanned_pairs_pct: pct(unplanned_pairs, length(pair_records))
    }

    {:ok, %{chart_specs: chart_specs, metrics: metrics, fetch_cache_state: cache_state}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_chart_specs(pair_records) do
    matrix_data = PairingAnalysis.pair_matrix(pair_records)
    trend_data = PairingAnalysis.trend_by_week(pair_records)
    workstream_data = PairingAnalysis.by_workstream(pair_records)

    top_pairs_data =
      pair_records
      |> Enum.frequencies_by(&{&1.person_a, &1.person_b})
      |> Enum.sort_by(fn {_pair, count} -> count end, :desc)
      |> Enum.take(15)
      |> Enum.map(fn {{a, b}, count} -> %{pair: "#{a} + #{b}", count: count} end)

    firefighter_persons = PairingAnalysis.firefighters_by_person(pair_records)
    firefighter_pairs = PairingAnalysis.firefighters_by_pair(pair_records) |> Enum.take(15)

    interrupt_trend = PairingAnalysis.interrupt_trend_by_week(pair_records)
    interrupt_by_person = PairingAnalysis.interrupt_trend_by_person(pair_records)

    planned_unplanned = [
      %{type: "Planned", count: Enum.count(pair_records, &(!&1.is_unplanned))},
      %{type: "Unplanned", count: Enum.count(pair_records, & &1.is_unplanned)}
    ]

    involvement_by_person =
      firefighter_persons
      |> Enum.map(fn row -> %{person: row.person, total: row.total} end)
      |> Enum.sort_by(& &1.total, :desc)

    by_project =
      pair_records
      |> Enum.frequencies_by(&(&1.project || "(none)"))
      |> Enum.map(fn {project, pair_count} -> %{project: project, pair_count: pair_count} end)
      |> Enum.sort_by(& &1.pair_count, :desc)

    %{
      pair_matrix: pair_matrix_spec(matrix_data),
      pairing_trend: pairing_trend_spec(trend_data),
      pairing_by_workstream: pairing_workstream_spec(workstream_data),
      top_pairs: top_pairs_spec(top_pairs_data),
      firefighter_person: firefighter_person_spec(firefighter_persons),
      firefighter_pair: firefighter_pair_spec(firefighter_pairs),
      interrupt_aggregate: interrupt_aggregate_spec(interrupt_trend),
      interrupt_person: interrupt_person_spec(interrupt_by_person),
      planned_unplanned: planned_unplanned_spec(planned_unplanned),
      involvement_by_person: involvement_by_person_spec(involvement_by_person),
      pairing_by_project: pairing_by_project_spec(by_project)
    }
  end

  defp pair_matrix_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Pair Matrix",
      "width" => 500,
      "height" => 500,
      "data" => %{"values" => values},
      "mark" => %{"type" => "rect", "tooltip" => true},
      "encoding" => %{
        "x" => %{
          "field" => "person_a",
          "type" => "nominal",
          "title" => "Person",
          "sort" => "ascending"
        },
        "y" => %{
          "field" => "person_b",
          "type" => "nominal",
          "title" => "Person",
          "sort" => "ascending"
        },
        "color" => %{
          "field" => "count",
          "type" => "quantitative",
          "title" => "Times paired",
          "scale" => %{"scheme" => "blues"}
        }
      }
    }
  end

  defp pairing_trend_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Pairing Trend by Week",
      "width" => 700,
      "height" => 300,
      "data" => %{"values" => values},
      "layer" => [
        %{
          "mark" => %{"type" => "bar", "opacity" => 0.6},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
            "y" => %{
              "field" => "pair_count",
              "type" => "quantitative",
              "title" => "Pair occurrences"
            }
          }
        },
        %{
          "mark" => %{"type" => "line", "color" => "red", "point" => true},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal"},
            "y" => %{
              "field" => "unique_pairs",
              "type" => "quantitative",
              "title" => "Unique pairs"
            }
          }
        }
      ]
    }
  end

  defp pairing_workstream_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Pairing by Workstream",
      "width" => 500,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{
          "field" => "workstream",
          "type" => "nominal",
          "title" => "Workstream",
          "sort" => "-y"
        },
        "y" => %{"field" => "pair_count", "type" => "quantitative", "title" => "Pair occurrences"},
        "color" => %{
          "field" => "unique_pairs",
          "type" => "quantitative",
          "title" => "Unique pairs",
          "scale" => %{"scheme" => "oranges"}
        }
      }
    }
  end

  defp top_pairs_spec(values),
    do:
      simple_nominal_bar(
        values,
        "Top 15 Pairs",
        "pair",
        "count",
        "Pair",
        "Occurrences",
        "#3b82f6"
      )

  defp firefighter_person_spec(values),
    do:
      simple_nominal_bar(
        values,
        "Firefighters: Unplanned Work by Person",
        "person",
        "unplanned",
        "Person",
        "Unplanned Pair Occurrences",
        nil
      )

  defp firefighter_pair_spec(values),
    do:
      simple_nominal_bar(
        values,
        "Firefighter Pairs: Top 15",
        "pair",
        "unplanned",
        "Pair",
        "Unplanned Occurrences",
        "orangered"
      )

  defp interrupt_aggregate_spec(values),
    do:
      simple_time_bar(
        values,
        "Interrupt Frequency Over Time (Aggregate)",
        "interrupt_count",
        "Interrupt Count"
      )

  defp interrupt_person_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Interrupt Frequency by Person Over Time",
      "width" => 700,
      "height" => 400,
      "data" => %{"values" => values},
      "mark" => %{"type" => "line", "point" => true, "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
        "y" => %{
          "field" => "interrupt_count",
          "type" => "quantitative",
          "title" => "Interrupt Count"
        },
        "color" => %{"field" => "person", "type" => "nominal", "title" => "Person"}
      }
    }
  end

  defp planned_unplanned_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Planned vs Unplanned Pair Occurrences",
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

  defp involvement_by_person_spec(values),
    do:
      simple_nominal_bar(
        values,
        "Pair Involvement by Person",
        "person",
        "total",
        "Person",
        "Pair Involvement",
        "#10b981"
      )

  defp pairing_by_project_spec(values),
    do:
      simple_nominal_bar(
        values,
        "Pairing by Project",
        "project",
        "pair_count",
        "Project",
        "Pair Occurrences",
        "#8b5cf6"
      )

  defp simple_nominal_bar(values, title, x_field, y_field, x_title, y_title, color) do
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
        "x" => %{"field" => x_field, "type" => "nominal", "title" => x_title, "sort" => "-y"},
        "y" => %{"field" => y_field, "type" => "quantitative", "title" => y_title}
      }
    }
  end

  defp simple_time_bar(values, title, y_field, y_title) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "width" => 700,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true, "color" => "orangered"},
      "encoding" => %{
        "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
        "y" => %{"field" => y_field, "type" => "quantitative", "title" => y_title}
      }
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="metrics-shell">
        <.metrics_sidebar
          config={@config}
          active_section="pairing"
          freshness={@fetch_cache_state}
        />

      <section class="metrics-content">
        <div class="space-y-6 pb-10">
          <div class="metrics-card-strong rounded-[2rem] px-6 py-6 sm:px-8">
            <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <p class="text-xs uppercase tracking-[0.28em] text-orange-200/70">Section</p>
                <h2 class="metrics-brand mt-2 text-4xl leading-none text-stone-50">Pairing</h2>
                <p class="mt-3 text-stone-300">Collaboration matrix, firefighter patterns, and interrupt trends.</p>
              </div>
              <div class="flex gap-2">
                <button id="toggle-pairing-config" type="button" phx-click="toggle_config" class="rounded-lg border border-orange-300/30 bg-orange-300/10 px-4 py-2 text-sm text-orange-100 hover:bg-orange-300/20">{if(@config_open?, do: "Hide config", else: "Show config")}</button>
                <button id="fetch-pairing-data" type="button" phx-click="fetch_data" class="rounded-lg bg-orange-400 px-4 py-2 text-sm font-semibold text-stone-950 hover:bg-orange-300">Fetch (cache)</button>
                <button id="fetch-pairing-data-refresh" type="button" phx-click="fetch_data" phx-value-refresh="true" class="rounded-lg border border-orange-300/30 px-4 py-2 text-sm text-orange-100 hover:bg-orange-300/10">Refresh (API)</button>
                <button id="clear-pairing-cache" type="button" phx-click="clear_cache" class="rounded-lg border border-white/10 px-4 py-2 text-sm text-stone-200 hover:border-orange-300/40 hover:text-orange-100">Clear cache</button>
              </div>
            </div>
            <%= if @fetch_cache_state do %>
              <p id="pairing-cache-state" class="mt-3 text-xs uppercase tracking-[0.2em] text-orange-200/70">
                Last fetch source: {cache_state_label(@fetch_cache_state)}
              </p>
            <% end %>
          </div>

          <%= if @fetch_error do %>
            <div class="metrics-card rounded-[2rem] border border-red-400/30 bg-red-500/10 p-5 text-red-200">{@fetch_error}</div>
          <% end %>

          <%= if @config_open? do %>
            <section class="metrics-card rounded-[2rem] p-6">
              <p class="text-xs uppercase tracking-[0.24em] text-stone-400">Configuration</p>
              <.form for={@config_form} id="pairing-config-form" phx-change="config_changed" class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
                <.input field={@config_form[:base_url]} type="text" label="Base URL" />
                <.input field={@config_form[:token]} type="password" label="Token" />
                <.input field={@config_form[:base_query]} type="text" label="Base query" />
                <.input field={@config_form[:days_back]} type="number" label="Days back" />
                <.input field={@config_form[:assignees_field]} type="text" label="Assignees field" />
                <.input field={@config_form[:project_prefix]} type="text" label="Project prefix" />
                <.input field={@config_form[:excluded_logins]} type="text" label="Excluded logins (CSV)" />
                <.input field={@config_form[:workstreams_path]} type="text" label="Workstreams path" />
                <.input field={@config_form[:include_substreams]} type="select" label="Include substreams" options={[{"Yes", "true"}, {"No", "false"}]} />
                <.input field={@config_form[:unplanned_tag]} type="text" label="Unplanned tag" />
              </.form>
            </section>
          <% end %>

          <%= if @loading? do %>
            <div class="metrics-card rounded-[2rem] p-10 text-center text-stone-300">
              <div class="mx-auto mb-4 h-10 w-10 animate-spin rounded-full border-4 border-stone-700 border-t-orange-400"></div>
              Fetching issues and extracting pair records...
            </div>
          <% end %>

          <div class="metrics-grid">
            <.stat_card label="Total issues" value={metric(@metrics, :total_issues)} tone="neutral" />
            <.stat_card label="Paired issues" value={metric(@metrics, :paired_issues)} tone="success" />
            <.stat_card label="Paired issues %" value={metric(@metrics, :paired_issues_pct)} tone="accent" />
            <.stat_card label="Pair occurrences" value={metric(@metrics, :pair_occurrences)} tone="neutral" />
            <.stat_card label="Unplanned pairs" value={metric(@metrics, :unplanned_pairs)} tone="warning" />
            <.stat_card label="Unplanned pairs %" value={metric(@metrics, :unplanned_pairs_pct)} tone="warning" />
          </div>

          <%= if map_size(@chart_specs) > 0 do %>
            <div class="grid gap-6 xl:grid-cols-[15rem_minmax(0,1fr)] xl:items-start">
              <.chart_toc title="Pairing Charts" items={chart_nav_items()} />

              <div class="grid gap-6 md:grid-cols-2">
                <.chart_card id="pairing-matrix-chart" title="Pair Matrix" spec={@chart_specs.pair_matrix} wrapper_class="md:col-span-2" class="h-[34rem]" />
                <.chart_card id="pairing-trend-chart" title="Pairing Trend" spec={@chart_specs.pairing_trend} wrapper_class="md:col-span-2" />
                <.chart_card id="pairing-workstream-chart" title="Pairing by Workstream" spec={@chart_specs.pairing_by_workstream} class="h-96" />
                <.chart_card id="pairing-top-pairs-chart" title="Top Pairs" spec={@chart_specs.top_pairs} class="h-96" />
                <.chart_card id="pairing-firefighter-person-chart" title="Firefighters by Person" spec={@chart_specs.firefighter_person} class="h-96" />
                <.chart_card id="pairing-firefighter-pair-chart" title="Firefighters by Pair" spec={@chart_specs.firefighter_pair} class="h-96" />
                <.chart_card id="pairing-interrupt-aggregate-chart" title="Interrupt Trend (Aggregate)" spec={@chart_specs.interrupt_aggregate} class="h-96" />
                <.chart_card id="pairing-interrupt-person-chart" title="Interrupt Trend by Person" spec={@chart_specs.interrupt_person} wrapper_class="md:col-span-2" />
                <.chart_card id="pairing-planned-unplanned-chart" title="Planned vs Unplanned" spec={@chart_specs.planned_unplanned} class="h-96" />
                <.chart_card id="pairing-involvement-chart" title="Pair Involvement by Person" spec={@chart_specs.involvement_by_person} class="h-96" />
                <.chart_card id="pairing-by-project-chart" title="Pairing by Project" spec={@chart_specs.pairing_by_project} class="h-96" />
              </div>
            </div>
          <% end %>
        </div>
      </section>
      </div>
    </Layouts.app>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:tone, :string, default: "neutral")

  defp stat_card(assigns) do
    ~H"""
    <div class={["rounded-[1.5rem] border px-4 py-4", stat_card_classes(@tone)]}>
      <p class="text-xs uppercase tracking-[0.22em] text-stone-400">{@label}</p>
      <p class="mt-3 text-xl font-semibold text-stone-50">{@value}</p>
    </div>
    """
  end

  defp stat_card_classes("accent"), do: "border-orange-200/20 bg-orange-200/5 text-orange-100"
  defp stat_card_classes("success"), do: "border-emerald-200/20 bg-emerald-200/5 text-emerald-100"
  defp stat_card_classes("warning"), do: "border-yellow-200/20 bg-yellow-200/5 text-yellow-100"
  defp stat_card_classes(_), do: "border-stone-500/20 bg-stone-500/5"

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

  defp chart_nav_items do
    [
      %{id: "pairing-matrix-chart", title: "Pair Matrix"},
      %{id: "pairing-trend-chart", title: "Pairing Trend"},
      %{id: "pairing-workstream-chart", title: "Pairing by Workstream"},
      %{id: "pairing-top-pairs-chart", title: "Top Pairs"},
      %{id: "pairing-firefighter-person-chart", title: "Firefighters by Person"},
      %{id: "pairing-firefighter-pair-chart", title: "Firefighters by Pair"},
      %{id: "pairing-interrupt-aggregate-chart", title: "Interrupt Trend (Aggregate)"},
      %{id: "pairing-interrupt-person-chart", title: "Interrupt Trend by Person"},
      %{id: "pairing-planned-unplanned-chart", title: "Planned vs Unplanned"},
      %{id: "pairing-involvement-chart", title: "Pair Involvement by Person"},
      %{id: "pairing-by-project-chart", title: "Pairing by Project"}
    ]
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

  defp validate_config(config) do
    cond do
      blank?(config["base_url"]) -> {:error, "Base URL is required"}
      blank?(config["token"]) -> {:error, "Token is required"}
      blank?(config["base_query"]) -> {:error, "Base query is required"}
      true -> :ok
    end
  end

  defp filter_by_project_prefix(issues, ""), do: issues

  defp filter_by_project_prefix(issues, prefix) do
    Enum.filter(issues, fn issue ->
      String.starts_with?(issue["idReadable"] || "", prefix)
    end)
  end

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

  defp pct(_part, 0), do: 0.0
  defp pct(part, total), do: Float.round(part / total * 100, 1)
end
