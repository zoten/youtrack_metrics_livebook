defmodule YoutrackWeb.ComparisonLive do
  @moduledoc """
  Comparison LiveView for side-by-side timeline analysis of multiple issues.
  """

  use YoutrackWeb, :live_view

  alias Youtrack.CardFocus
  alias Youtrack.Client
  alias Youtrack.WeeklyReport
  alias YoutrackWeb.Charts.Comparison, as: ComparisonCharts
  alias YoutrackWeb.Configuration
  alias YoutrackWeb.ConfigVisibilityPreference

  @issue_fields [
    "idReadable",
    "id",
    "summary",
    "description",
    "created",
    "updated",
    "resolved",
    "project(shortName)",
    "type(name)",
    "tags(name)",
    "comments(id,text,created,author(name,login))",
    "customFields(name,value(name,login,text))"
  ]

  @activity_categories "CustomFieldCategory,TagsCategory,DescriptionCategory"
  @max_cards 4

  @impl true
  def mount(params, _session, socket) do
    defaults =
      Configuration.defaults()
      |> Configuration.merge_shared(Configuration.shared_from_socket(socket))

    config_open? = ConfigVisibilityPreference.from_socket(socket)

    # Parse issue IDs from query params (comma-separated)
    issue_ids = parse_issue_ids(params["ids"])

    {:ok,
     socket
     |> assign(:current_scope, nil)
     |> assign(:page_title, "Card Comparison")
     |> assign(:config_open?, config_open?)
     |> assign(:loading?, false)
     |> assign(:fetch_error, nil)
     |> assign(:config, defaults)
     |> assign(:config_form, to_form(defaults, as: :config))
     |> assign(:issue_ids, issue_ids)
     |> assign(
       :selector_form,
       to_form(%{"issue_ids" => issue_ids_to_string(issue_ids)}, as: :selector)
     )
     |> assign(:selector_error, nil)
     |> assign(:card_data_map, %{})
     |> assign(:loading_ids, MapSet.new())
     |> assign(:fetch_errors, %{})
     |> assign(:task_ref_to_issue_id, %{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    issue_ids = parse_issue_ids(params["ids"])

    card_data_map =
      socket.assigns.card_data_map
      |> Enum.filter(fn {issue_id, _card_data} -> issue_id in issue_ids end)
      |> Map.new()

    fetch_errors =
      socket.assigns.fetch_errors
      |> Enum.filter(fn {issue_id, _error} -> issue_id in issue_ids end)
      |> Map.new()

    loading_ids =
      socket.assigns.loading_ids
      |> Enum.filter(&(&1 in issue_ids))
      |> MapSet.new()

    {:noreply,
     socket
     |> assign(:issue_ids, issue_ids)
     |> assign(
       :selector_form,
       to_form(%{"issue_ids" => issue_ids_to_string(issue_ids)}, as: :selector)
     )
     |> assign(:card_data_map, card_data_map)
     |> assign(:fetch_errors, fetch_errors)
     |> assign(:loading_ids, loading_ids)
     |> assign(:loading?, MapSet.size(loading_ids) > 0)}
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
  def handle_event("add_cards", %{"selector" => params}, socket) do
    new_ids = parse_issue_ids(params["issue_ids"])

    # Merge with existing issue IDs
    all_ids = (socket.assigns.issue_ids ++ new_ids) |> Enum.uniq()

    # Enforce max cards limit
    truncated_ids = Enum.take(all_ids, @max_cards)

    cond do
      Enum.empty?(truncated_ids) ->
        {:noreply,
         socket
         |> assign(:selector_error, "At least one issue ID is required")
         |> assign(:selector_form, to_form(%{"issue_ids" => ""}, as: :selector))}

      length(truncated_ids) < length(all_ids) ->
        {:noreply,
         socket
         |> assign(
           :selector_error,
           "Maximum #{@max_cards} cards allowed. Showing first #{@max_cards}."
         )
         |> push_patch(to: ~p"/compare?ids=#{issue_ids_to_url_string(truncated_ids)}")}

      true ->
        {:noreply,
         socket
         |> assign(:selector_error, nil)
         |> push_patch(to: ~p"/compare?ids=#{issue_ids_to_url_string(truncated_ids)}")}
    end
  end

  @impl true
  def handle_event("remove_card", %{"id" => issue_id}, socket) do
    remaining_ids = Enum.reject(socket.assigns.issue_ids, &(&1 == issue_id))

    {:noreply,
     socket
     |> push_patch(to: ~p"/compare?ids=#{issue_ids_to_url_string(remaining_ids)}")}
  end

  @impl true
  def handle_event("fetch_comparison", _params, socket) do
    case validate_fetch(socket.assigns.config, socket.assigns.issue_ids) do
      :ok ->
        {:noreply,
         socket
         |> assign(:loading?, true)
         |> assign(:fetch_error, nil)
         |> start_fetch_all_tasks(socket.assigns.config, socket.assigns.issue_ids)}

      {:error, message} ->
        {:noreply, assign(socket, :fetch_error, message)}
    end
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

    issue_id = result.issue_id
    card_data = result.card_data

    loading_ids = MapSet.delete(socket.assigns.loading_ids, issue_id)
    task_ref_to_issue_id = Map.delete(socket.assigns.task_ref_to_issue_id, ref)
    fetch_errors = Map.delete(socket.assigns.fetch_errors, issue_id)

    {:noreply,
     socket
     |> assign(:loading_ids, loading_ids)
     |> assign(:task_ref_to_issue_id, task_ref_to_issue_id)
     |> assign(:fetch_errors, fetch_errors)
     |> assign(:card_data_map, Map.put(socket.assigns.card_data_map, issue_id, card_data))
     |> then(fn s ->
       if MapSet.size(loading_ids) == 0, do: assign(s, :loading?, false), else: s
     end)}
  end

  @impl true
  def handle_info({ref, {:error, %{issue_id: issue_id, reason: reason}}}, socket) do
    Process.demonitor(ref, [:flush])

    loading_ids = MapSet.delete(socket.assigns.loading_ids, issue_id)
    task_ref_to_issue_id = Map.delete(socket.assigns.task_ref_to_issue_id, ref)
    fetch_errors = Map.put(socket.assigns.fetch_errors, issue_id, reason)

    {:noreply,
     socket
     |> assign(:loading_ids, loading_ids)
     |> assign(:task_ref_to_issue_id, task_ref_to_issue_id)
     |> assign(:fetch_errors, fetch_errors)
     |> assign(:fetch_error, "Comparison fetch failed for #{issue_id}: #{reason}")
     |> then(fn s ->
       if MapSet.size(loading_ids) == 0, do: assign(s, :loading?, false), else: s
     end)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    {issue_id, task_ref_to_issue_id} = Map.pop(socket.assigns.task_ref_to_issue_id, ref)

    loading_ids =
      if issue_id do
        MapSet.delete(socket.assigns.loading_ids, issue_id)
      else
        socket.assigns.loading_ids
      end

    fetch_errors =
      if issue_id do
        Map.put(socket.assigns.fetch_errors, issue_id, "Task crashed: #{inspect(reason)}")
      else
        socket.assigns.fetch_errors
      end

    fetch_error =
      if issue_id do
        "Comparison fetch failed for #{issue_id}: task crashed"
      else
        "Background task crashed: #{inspect(reason)}"
      end

    {:noreply,
     socket
     |> assign(:task_ref_to_issue_id, task_ref_to_issue_id)
     |> assign(:loading_ids, loading_ids)
     |> assign(:fetch_errors, fetch_errors)
     |> assign(:loading?, MapSet.size(loading_ids) > 0)
     |> assign(:fetch_error, fetch_error)}
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
      active_section="comparison"
      topbar_label="Card Comparison"
      topbar_hint="Compare 2-4 issues side by side with aligned timelines and metrics."
    >
      <div class="mx-auto max-w-7xl space-y-6">
        <section class="metrics-card-strong rounded-[2rem] px-6 py-6 sm:px-8">
          <div class="space-y-6">
            <div class="space-y-3">
              <p class="metrics-eyebrow text-xs uppercase tracking-[0.28em]">Parallel view</p>
              <h2 class="metrics-brand metrics-title text-5xl leading-none">
                Compare cards at a glance
              </h2>
              <p class="metrics-copy max-w-3xl text-base leading-7">
                Add 2-4 issues to view their timelines side by side. Inspect state transitions, activity periods,
                comments, tags, and metrics in a unified layout for quick comparison.
              </p>
            </div>

            <.form
              for={@selector_form}
              id="comparison-card-selector"
              phx-submit="add_cards"
              class="space-y-4"
            >
              <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_auto] md:items-end">
                <.input
                  field={@selector_form[:issue_ids]}
                  id="comparison-issue-ids"
                  type="text"
                  label="Issue IDs (comma-separated)"
                  placeholder="PROJ-123, PROJ-456"
                />
                <button
                  id="comparison-add-cards"
                  type="submit"
                  class="metrics-button metrics-button-primary h-11 px-5 text-sm font-semibold"
                >
                  Add cards
                </button>
              </div>
            </.form>

            <%= if @selector_error do %>
              <div class="metrics-subtle-panel rounded-2xl p-4">
                <p id="comparison-selector-error" class="metrics-title text-sm font-semibold">
                  {@selector_error}
                </p>
              </div>
            <% end %>

            <%= if not Enum.empty?(@issue_ids) do %>
              <div class="flex flex-wrap gap-2">
                <%= for issue_id <- @issue_ids do %>
                  <div class="metrics-pill metrics-pill-accent px-3 py-2 text-xs tracking-normal flex items-center gap-2">
                    <.link navigate={~p"/card/#{issue_id}"} class="hover:underline">{issue_id}</.link>
                    <button
                      id={"comparison-remove-#{issue_id}"}
                      type="button"
                      phx-click="remove_card"
                      phx-value-id={issue_id}
                      class="hover:opacity-70"
                    >
                      ✕
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </section>

        <%= if Enum.empty?(@issue_ids) do %>
          <section class="metrics-card rounded-[2rem] p-6">
            <p class="metrics-copy text-sm leading-6">
              Add 2-4 issue IDs above to get started. The page will display aligned Gantt charts, event timelines,
              and a metric comparison table for quick analysis.
            </p>
          </section>
        <% else %>
          <div class="grid gap-6 xl:grid-cols-[minmax(0,1.05fr)_minmax(20rem,0.95fr)]">
            <section class="metrics-card rounded-[2rem] p-6">
              <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Fetch</p>
              <h3 class="metrics-title mt-2 text-2xl font-semibold">Load comparison data</h3>
              <p class="metrics-copy mt-2 max-w-2xl text-sm leading-6">
                Fetch issue history and state transitions for the selected cards.
              </p>

              <div class="mt-5 flex flex-wrap gap-3">
                <button
                  id="comparison-fetch"
                  type="button"
                  phx-click="fetch_comparison"
                  class="metrics-button metrics-button-primary px-5 text-sm font-semibold"
                >
                  Load comparison
                </button>
                <button
                  id="reload-comparison-config"
                  type="button"
                  phx-click="reload_config"
                  class="metrics-button metrics-button-ghost px-5 text-sm font-semibold"
                >
                  Reload config
                </button>
              </div>

              <%= if map_size(@card_data_map) == 0 do %>
                <div class="mt-6 grid gap-4 md:grid-cols-2">
                  <.comparison_stub_card
                    id="comparison-gantt-stub"
                    title="Shared Gantt chart"
                    summary="State transitions and activity periods aligned on a single timeline."
                  />
                  <.comparison_stub_card
                    id="comparison-events-stub"
                    title="Event timelines"
                    summary="Comments, tags, and state changes as points on a shared horizontal axis."
                  />
                  <.comparison_stub_card
                    id="comparison-metrics-stub"
                    title="Metric table"
                    summary="Cycle time, net active, inactive, and comment counts compared side by side."
                  />
                  <.comparison_stub_card
                    id="comparison-insights-stub"
                    title="Quick insights"
                    summary="Highlight the fastest, slowest, most active, and most commented cards."
                  />
                </div>
              <% end %>
            </section>

            <aside class="space-y-6">
              <section class="metrics-card rounded-[2rem] p-6">
                <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Fetch state</p>
                <div class="metrics-copy mt-4 space-y-4 text-sm leading-6">
                  <%= if @loading? do %>
                    <div id="comparison-loading" class="metrics-subtle-panel rounded-2xl p-4">
                      Loading comparison for {Enum.count(@loading_ids)} item(s)...
                    </div>
                  <% else %>
                    <div class="metrics-subtle-panel rounded-2xl p-4">
                      Ready
                    </div>
                  <% end %>

                  <%= if @fetch_error do %>
                    <div id="comparison-error" class="metrics-subtle-panel rounded-2xl p-4">
                      {@fetch_error}
                    </div>
                  <% end %>

                  <%= if map_size(@fetch_errors) > 0 do %>
                    <div id="comparison-errors-by-card" class="space-y-2">
                      <%= for {issue_id, reason} <- @fetch_errors do %>
                        <div class="metrics-subtle-panel rounded-2xl p-4">
                          <p class="metrics-title text-sm font-semibold">{issue_id}</p>
                          <p class="metrics-copy mt-1 text-xs leading-5">{reason}</p>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </section>
            </aside>
          </div>

          <%= if map_size(@card_data_map) > 0 do %>
            <section id="comparison-results" class="space-y-6">
              <div class="metrics-card rounded-[2rem] p-6">
                <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Loaded</p>
                <h3 class="metrics-title mt-2 text-2xl font-semibold">
                  {map_size(@card_data_map)} of {length(@issue_ids)} cards loaded
                </h3>
                <%= if map_size(@card_data_map) < 2 do %>
                  <p class="metrics-copy mt-2 max-w-2xl text-sm leading-6">
                    Load at least two cards to render the shared comparison Gantt timeline.
                  </p>
                <% else %>
                  <p class="metrics-copy mt-2 max-w-2xl text-sm leading-6">
                    Shared Gantt timeline and metrics comparison table are ready.
                  </p>
                <% end %>
              </div>

              <section id="comparison-metrics" class="metrics-card rounded-[2rem] p-6">
                <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Metrics</p>
                <h3 class="metrics-title mt-2 text-2xl font-semibold">Side-by-side metrics</h3>
                <div class="mt-4 overflow-x-auto">
                  <table class="w-full text-sm">
                    <thead>
                      <tr class="metrics-copy border-b text-xs uppercase tracking-[0.2em]">
                        <th class="pb-3 text-left font-medium">Issue</th>
                        <th class="pb-3 text-right font-medium">Cycle time</th>
                        <th class="pb-3 text-right font-medium">Net active</th>
                        <th class="pb-3 text-right font-medium">Inactive</th>
                        <th class="pb-3 text-right font-medium">Active ratio</th>
                        <th class="pb-3 text-right font-medium">Comments</th>
                        <th class="pb-3 text-right font-medium">Rework</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for row <- comparison_metrics_rows(@issue_ids, @card_data_map) do %>
                        <tr
                          id={"comparison-metrics-row-#{row.issue_key}"}
                          class="border-b last:border-0 transition-colors hover:bg-black/5"
                        >
                          <td class="metrics-title py-3 font-mono text-sm font-semibold">{row.issue_key}</td>
                          <td class={["py-3 text-right tabular-nums", highlight_class(row.highlights.cycle_time_ms)]}>
                            {format_duration(row.metrics.cycle_time_ms)}
                          </td>
                          <td class={["py-3 text-right tabular-nums", highlight_class(row.highlights.net_active_time_ms)]}>
                            {format_duration(row.metrics.net_active_time_ms)}
                          </td>
                          <td class={["py-3 text-right tabular-nums", highlight_class(row.highlights.inactive_time_ms)]}>
                            {format_duration(row.metrics.inactive_time_ms)}
                          </td>
                          <td class={["py-3 text-right tabular-nums", highlight_class(row.highlights.active_ratio_pct)]}>
                            {format_ratio(row.metrics.active_ratio_pct)}
                          </td>
                          <td class={["py-3 text-right tabular-nums", highlight_class(row.highlights.comment_count)]}>
                            {row.metrics.comment_count}
                          </td>
                          <td class={["py-3 text-right tabular-nums", highlight_class(row.highlights.rework_count)]}>
                            {row.metrics.rework_count}
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              </section>

              <%= if map_size(@card_data_map) >= 2 do %>
                <.chart_card
                  id="comparison-gantt"
                  title="Parallel state timeline"
                  description="All loaded cards aligned on a shared time axis, with state and activity lanes per issue."
                  spec={comparison_gantt_spec(@issue_ids, @card_data_map)}
                  class="h-[28rem]"
                  wrapper_class="p-4"
                />

                <div class="space-y-6">
                  <.chart_card
                    id="comparison-state-events"
                    title="State change timeline"
                    description="Transition points aligned across cards for quick flow comparison."
                    spec={comparison_state_events_spec(@issue_ids, @card_data_map)}
                    class="h-72"
                    wrapper_class="p-4"
                  />

                  <.chart_card
                    id="comparison-comments"
                    title="Comments timeline"
                    description="Comment activity shown as horizontal point markers on the shared issue axis."
                    spec={comparison_comment_events_spec(@issue_ids, @card_data_map)}
                    class="h-72"
                    wrapper_class="p-4"
                  />

                  <.chart_card
                    id="comparison-tags"
                    title="Tag change timeline"
                    description="Added and removed tags highlighted on a shared event timeline."
                    spec={comparison_tag_events_spec(@issue_ids, @card_data_map)}
                    class="h-72"
                    wrapper_class="p-4"
                  />
                </div>
              <% end %>
            </section>
          <% end %>
        <% end %>
      </div>
    </Layouts.dashboard>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:summary, :string, required: true)

  defp comparison_stub_card(assigns) do
    ~H"""
    <div id={@id} class="metrics-subtle-panel rounded-[1.5rem] p-4">
      <p class="metrics-title text-lg font-semibold">{@title}</p>
      <p class="metrics-copy mt-2 text-sm leading-6">{@summary}</p>
    </div>
    """
  end

  defp parse_issue_ids(nil), do: []

  defp parse_issue_ids(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_issue_ids(_), do: []

  defp issue_ids_to_string(ids) when is_list(ids) do
    Enum.join(ids, ", ")
  end

  defp issue_ids_to_url_string(ids) when is_list(ids) do
    Enum.join(ids, ",")
  end

  defp validate_fetch(config, issue_ids) do
    cond do
      Enum.empty?(issue_ids) -> {:error, "At least one issue ID is required"}
      blank?(config["base_url"]) -> {:error, "Base URL is required"}
      blank?(config["token"]) -> {:error, "Token is required"}
      true -> :ok
    end
  end

  defp start_fetch_all_tasks(socket, config, issue_ids) do
    pending_ids =
      issue_ids
      |> Enum.reject(&Map.has_key?(socket.assigns.card_data_map, &1))

    if pending_ids == [] do
      socket
      |> assign(:loading?, false)
      |> assign(:loading_ids, MapSet.new())
    else
      {loading_ids, task_ref_to_issue_id} =
        Enum.reduce(pending_ids, {MapSet.new(), socket.assigns.task_ref_to_issue_id}, fn issue_id,
                                                                                         {ids_acc,
                                                                                          refs_acc} ->
          task =
            Task.Supervisor.async_nolink(YoutrackWeb.TaskSupervisor, fn ->
              fetch_card_data(config, issue_id)
            end)

          {MapSet.put(ids_acc, issue_id), Map.put(refs_acc, task.ref, issue_id)}
        end)

      fetch_errors = Map.drop(socket.assigns.fetch_errors, pending_ids)

      socket
      |> assign(:loading_ids, loading_ids)
      |> assign(:task_ref_to_issue_id, task_ref_to_issue_id)
      |> assign(:fetch_errors, fetch_errors)
      |> assign(:loading?, true)
    end
  end

  defp fetch_card_data(config, issue_id) do
    base_url = String.trim(config["base_url"] || "")
    token = String.trim(config["token"] || "")
    state_field = String.trim(config["state_field"] || "State")
    assignees_field = String.trim(config["assignees_field"] || "Assignee")
    done_names = csv_list(config["done_state_names"])
    in_progress_names = csv_list(config["in_progress_names"])

    req = Client.new!(base_url, token)

    issue = fetch_issue!(req, issue_id)

    {:ok, activities} =
      safe_fetch_activities(req, issue["id"])

    card_data =
      CardFocus.build(
        issue,
        activities,
        state_field: state_field,
        assignees_field: assignees_field,
        in_progress_names: default_if_empty(in_progress_names, ["In Progress"]),
        inactive_names: ["To Do", "Todo", "Open", "Backlog"],
        done_names: default_if_empty(done_names, ["Done", "Won't Do"]),
        hold_tags: ["on hold", "blocked"],
        workstreams: []
      )

    {:ok, %{issue_id: issue_id, card_data: card_data}}
  rescue
    error -> {:error, %{issue_id: issue_id, reason: Exception.message(error)}}
  end

  defp fetch_issue!(req, issue_id) do
    issue =
      ["id: #{issue_id}", issue_id]
      |> Enum.find_value(fn query ->
        req
        |> Client.fetch_issues!(query, fields: @issue_fields, top: 5)
        |> Enum.find(fn issue -> issue["idReadable"] == issue_id end)
      end)

    case issue do
      nil -> raise "Issue not found: #{issue_id}"
      _ -> issue
    end
  end

  defp safe_fetch_activities(req, issue_id) do
    try do
      activities = Client.fetch_activities!(req, issue_id, categories: @activity_categories)
      {:ok, activities}
    rescue
      _error -> {:ok, []}
    end
  end

  defp default_if_empty([], fallback), do: fallback
  defp default_if_empty(values, _fallback), do: values

  defp csv_list(nil), do: []

  defp csv_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp csv_list(_value), do: []

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp comparison_gantt_spec(issue_ids, card_data_map) do
    ComparisonCharts.shared_timeline_spec(ordered_cards(issue_ids, card_data_map))
  end

  defp comparison_state_events_spec(issue_ids, card_data_map) do
    ComparisonCharts.state_events_timeline_spec(ordered_cards(issue_ids, card_data_map))
  end

  defp comparison_comment_events_spec(issue_ids, card_data_map) do
    ComparisonCharts.comment_timeline_spec(ordered_cards(issue_ids, card_data_map))
  end

  defp comparison_tag_events_spec(issue_ids, card_data_map) do
    ComparisonCharts.tag_timeline_spec(ordered_cards(issue_ids, card_data_map))
  end

  defp ordered_cards(issue_ids, card_data_map) do
    issue_ids
    |> Enum.with_index(1)
    |> Enum.filter(fn {issue_id, _idx} -> Map.has_key?(card_data_map, issue_id) end)
    |> Enum.map(fn {issue_id, order_idx} ->
      %{issue_id: issue_id, issue_order: order_idx, card_data: card_data_map[issue_id]}
    end)
  end

  @metric_col_directions [
    {:cycle_time_ms, :lower},
    {:net_active_time_ms, :higher},
    {:inactive_time_ms, :lower},
    {:active_ratio_pct, :higher},
    {:comment_count, :neutral},
    {:rework_count, :lower}
  ]

  defp comparison_metrics_rows(issue_ids, card_data_map) do
    cards = ordered_cards(issue_ids, card_data_map)

    extremes =
      Enum.reduce(@metric_col_directions, %{}, fn
        {key, :neutral}, acc ->
          Map.put(acc, key, nil)

        {key, direction}, acc ->
          values =
            cards
            |> Enum.map(fn %{card_data: cd} -> Map.get(cd.metrics, key) end)
            |> Enum.reject(&is_nil/1)

          if length(values) >= 2 do
            {best, worst} =
              if direction == :lower,
                do: {Enum.min(values), Enum.max(values)},
                else: {Enum.max(values), Enum.min(values)}

            Map.put(acc, key, {best, worst})
          else
            Map.put(acc, key, nil)
          end
      end)

    Enum.map(cards, fn %{card_data: cd} ->
      highlights =
        Enum.reduce(@metric_col_directions, %{}, fn {key, _dir}, acc ->
          val = Map.get(cd.metrics, key)

          highlight =
            case extremes[key] do
              {best, worst} when val == best and best != worst -> :best
              {_best, worst} when val == worst -> :worst
              _ -> :neutral
            end

          Map.put(acc, key, highlight)
        end)

      %{issue_key: cd.issue.issue_key, metrics: cd.metrics, highlights: highlights}
    end)
  end

  defp highlight_class(:best), do: "font-semibold text-emerald-600"
  defp highlight_class(:worst), do: "text-rose-500"
  defp highlight_class(:neutral), do: ""

  defp format_duration(nil), do: "N/A"
  defp format_duration(ms), do: WeeklyReport.format_duration(ms)

  defp format_ratio(nil), do: "N/A"
  defp format_ratio(value), do: "#{value}%"
end
