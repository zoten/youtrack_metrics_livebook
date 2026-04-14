defmodule YoutrackWeb.PairingLive do
  @moduledoc """
  Pairing section with collaboration, firefighter, and interrupt analytics.
  """

  use YoutrackWeb, :live_view

  alias Youtrack.Client
  alias Youtrack.PairingAnalysis
  alias Youtrack.WorkstreamsLoader
  alias YoutrackWeb.Charts.Pairing, as: PairingCharts
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
      |> assign(:page_title, "Pairing")
      |> assign(:config_open?, config_open?)
      |> assign(:loading?, false)
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

    chart_specs = PairingCharts.build_chart_specs(pair_records)

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_scope}
      config={@config}
      config_form={@config_form}
      config_open?={@config_open?}
      active_section="pairing"
      freshness={@fetch_cache_state}
      topbar_label="Pairing"
      topbar_hint="Collaboration patterns and interrupt analysis across the team."
    >
      <div class="space-y-6 pb-10">
        <div class="metrics-card-strong rounded-[2rem] px-6 py-6 sm:px-8">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p class="metrics-eyebrow text-xs uppercase tracking-[0.28em]">Section</p>
              <h2 class="metrics-brand metrics-title mt-2 text-4xl leading-none">Pairing</h2>
              <p class="metrics-copy mt-3">
                Collaboration matrix, firefighter patterns, and interrupt trends.
              </p>
            </div>
            <div class="flex gap-2">
              <button
                id="toggle-pairing-config"
                type="button"
                phx-click="toggle_config"
                class="metrics-button metrics-button-secondary"
              >
                {if(@config_open?, do: "Hide config", else: "Show config")}
              </button>
              <button
                id="fetch-pairing-data"
                type="button"
                phx-click="fetch_data"
                class="metrics-button metrics-button-primary font-semibold"
              >
                Fetch (cache)
              </button>
              <button
                id="fetch-pairing-data-refresh"
                type="button"
                phx-click="fetch_data"
                phx-value-refresh="true"
                class="metrics-button metrics-button-secondary"
              >
                Refresh (API)
              </button>
              <button
                id="reload-pairing-config"
                type="button"
                phx-click="reload_config"
                class="metrics-button metrics-button-secondary"
              >
                Reload Configuration
              </button>
              <button
                id="clear-pairing-cache"
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
              id="pairing-cache-state"
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
            Fetching issues and extracting pair records...
          </div>
        <% end %>

        <div class="metrics-grid">
          <.stat_card label="Total issues" value={metric(@metrics, :total_issues)} tone="neutral" />
          <.stat_card label="Paired issues" value={metric(@metrics, :paired_issues)} tone="success" />
          <.stat_card
            label="Paired issues %"
            value={metric(@metrics, :paired_issues_pct)}
            tone="accent"
          />
          <.stat_card
            label="Pair occurrences"
            value={metric(@metrics, :pair_occurrences)}
            tone="neutral"
          />
          <.stat_card
            label="Unplanned pairs"
            value={metric(@metrics, :unplanned_pairs)}
            tone="warning"
          />
          <.stat_card
            label="Unplanned pairs %"
            value={metric(@metrics, :unplanned_pairs_pct)}
            tone="warning"
          />
        </div>

        <%= if map_size(@chart_specs) > 0 do %>
          <div
            id="pairing-charts-area"
            class="grid gap-6 xl:grid-cols-[15rem_minmax(0,1fr)] xl:items-start"
          >
            <div class="space-y-4 lg:sticky lg:top-6 lg:max-h-[calc(100vh-3rem)] lg:overflow-y-auto">
              <.collapse_controls target="#pairing-charts-area" />
              <.chart_toc title="Pairing Charts" items={chart_nav_items()} />
            </div>

            <div class="grid gap-6 md:grid-cols-2">
              <.chart_card
                id="pairing-matrix-chart"
                title="Pair Matrix"
                spec={@chart_specs.pair_matrix}
                wrapper_class="md:col-span-2"
                class="h-[34rem]"
              />
              <.chart_card
                id="pairing-trend-chart"
                title="Pairing Trend"
                spec={@chart_specs.pairing_trend}
                wrapper_class="md:col-span-2"
              />
              <.chart_card
                id="pairing-workstream-chart"
                title="Pairing by Workstream"
                spec={@chart_specs.pairing_by_workstream}
                class="h-96"
              />
              <.chart_card
                id="pairing-top-pairs-chart"
                title="Top Pairs"
                spec={@chart_specs.top_pairs}
                class="h-96"
              />
              <.chart_card
                id="pairing-firefighter-person-chart"
                title="Firefighters by Person"
                spec={@chart_specs.firefighter_person}
                class="h-96"
              />
              <.chart_card
                id="pairing-firefighter-pair-chart"
                title="Firefighters by Pair"
                spec={@chart_specs.firefighter_pair}
                class="h-96"
              />
              <.chart_card
                id="pairing-interrupt-aggregate-chart"
                title="Interrupt Trend (Aggregate)"
                spec={@chart_specs.interrupt_aggregate}
                class="h-96"
              />
              <.chart_card
                id="pairing-interrupt-person-chart"
                title="Interrupt Trend by Person"
                spec={@chart_specs.interrupt_person}
                wrapper_class="md:col-span-2"
              />
              <.chart_card
                id="pairing-planned-unplanned-chart"
                title="Planned vs Unplanned"
                spec={@chart_specs.planned_unplanned}
                class="h-96"
              />
              <.chart_card
                id="pairing-involvement-chart"
                title="Pair Involvement by Person"
                spec={@chart_specs.involvement_by_person}
                class="h-96"
              />
              <.chart_card
                id="pairing-by-project-chart"
                title="Pairing by Project"
                spec={@chart_specs.pairing_by_project}
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
    RuntimeConfig.workstream_rules()
  end

  defp load_rules(path) do
    if RuntimeConfig.workstreams_path() == path do
      RuntimeConfig.workstream_rules()
    else
      case WorkstreamsLoader.load_file(path) do
        {:ok, rules} -> rules
        {:error, _} -> WorkstreamsLoader.empty_rules()
      end
    end
  end

  defp config_reload_message({:file_change, _paths}),
    do: "Configuration changed on disk and was reloaded"

  defp config_reload_message(:manual), do: "Configuration reloaded"
  defp config_reload_message(_), do: "Configuration updated"

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
