defmodule YoutrackWeb.CardFocusLive do
  @moduledoc """
  Card-focused LiveView for exploring one issue across its full history.
  """

  use YoutrackWeb, :live_view

  alias Youtrack.CardFocus
  alias Youtrack.Client
  alias Youtrack.WeeklyReport
  alias Youtrack.Workstreams
  alias Youtrack.WorkstreamsLoader
  alias YoutrackWeb.CardTimelineFiltersPreference
  alias YoutrackWeb.Charts.CardFocus, as: CardFocusCharts
  alias YoutrackWeb.Configuration
  alias YoutrackWeb.ConfigVisibilityPreference
  alias YoutrackWeb.RuntimeConfig

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

  @impl true
  def mount(params, _session, socket) do
    defaults =
      Configuration.defaults()
      |> Configuration.merge_shared(Configuration.shared_from_socket(socket))

    config_open? = ConfigVisibilityPreference.from_socket(socket)
    timeline_filters = CardTimelineFiltersPreference.from_socket(socket)
    issue_id = normalize_issue_id(params["issue_id"])

    if connected?(socket) do
      Phoenix.PubSub.subscribe(YoutrackWeb.PubSub, RuntimeConfig.topic())

      if issue_id != nil do
        send(self(), :maybe_auto_fetch)
      end
    end

    {:ok,
     socket
     |> assign(:current_scope, nil)
     |> assign(:page_title, page_title(issue_id))
     |> assign(:config_open?, config_open?)
     |> assign(:loading?, false)
     |> assign(:fetch_error, nil)
     |> assign(:fetch_cache_state, nil)
     |> assign(:config, defaults)
     |> assign(:config_form, to_form(defaults, as: :config))
     |> assign(:issue_id, issue_id)
     |> assign(:lookup_form, to_form(%{"issue_id" => issue_id || ""}, as: :lookup))
     |> assign(:lookup_error, nil)
     |> assign(:card_data, nil)
     |> assign(:filtered_card_data, nil)
     |> assign(:exclude_todo?, timeline_filters.exclude_todo?)
     |> assign(:exclude_no_sprint?, timeline_filters.exclude_no_sprint?)}
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
     |> assign(:config_form, to_form(config, as: :config))
     |> with_filtered_card_data()}
  end

  @impl true
  def handle_event("toggle_exclude_todo", _params, socket) do
    exclude_todo? = !socket.assigns.exclude_todo?

    {:noreply,
     socket
     |> assign(:exclude_todo?, exclude_todo?)
     |> with_filtered_card_data()
     |> push_event("card_timeline_filters_changed", %{
       exclude_todo: exclude_todo?,
       exclude_no_sprint: socket.assigns.exclude_no_sprint?
     })}
  end

  @impl true
  def handle_event("toggle_exclude_no_sprint", _params, socket) do
    exclude_no_sprint? = !socket.assigns.exclude_no_sprint?

    {:noreply,
     socket
     |> assign(:exclude_no_sprint?, exclude_no_sprint?)
     |> with_filtered_card_data()
     |> push_event("card_timeline_filters_changed", %{
       exclude_todo: socket.assigns.exclude_todo?,
       exclude_no_sprint: exclude_no_sprint?
     })}
  end

  @impl true
  def handle_event("lookup_card", %{"lookup" => params}, socket) do
    issue_id = normalize_issue_id(params["issue_id"])

    case issue_id do
      nil ->
        {:noreply,
         socket
         |> assign(:lookup_error, "Issue ID is required")
         |> assign(:lookup_form, to_form(%{"issue_id" => ""}, as: :lookup))}

      value ->
        {:noreply,
         socket
         |> assign(:lookup_error, nil)
         |> assign(:issue_id, value)
         |> assign(:page_title, page_title(value))
         |> assign(:lookup_form, to_form(%{"issue_id" => value}, as: :lookup))
         |> push_navigate(to: ~p"/card/#{value}")}
    end
  end

  @impl true
  def handle_event("fetch_card", params, socket) do
    refresh? = params["refresh"] == "true"

    case validate_fetch(socket.assigns.config, socket.assigns.issue_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:loading?, true)
         |> assign(:fetch_error, nil)
         |> start_fetch_task(socket.assigns.config, socket.assigns.issue_id, refresh?)}

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
         |> with_filtered_card_data()
         |> put_flash(:info, "Reloaded .env and workstreams.yaml")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reload failed: #{reason}")}
    end
  end

  @impl true
  def handle_info(:maybe_auto_fetch, socket) do
    cond do
      socket.assigns.loading? ->
        {:noreply, socket}

      socket.assigns.issue_id == nil ->
        {:noreply, socket}

      validate_fetch(socket.assigns.config, socket.assigns.issue_id) != :ok ->
        {:noreply, socket}

      true ->
        {:noreply,
         socket
         |> assign(:loading?, true)
         |> assign(:fetch_error, nil)
         |> start_fetch_task(socket.assigns.config, socket.assigns.issue_id, false)}
    end
  end

  @impl true
  def handle_info({ref, {:ok, result}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:card_data, result.card_data)
     |> assign(:fetch_cache_state, result.fetch_cache_state)
     |> with_filtered_card_data()}
  end

  @impl true
  def handle_info({ref, {:error, reason}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:fetch_error, "Card fetch failed: #{reason}")}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:fetch_error, "Background task crashed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({:config_reloaded, payload}, socket) do
    defaults = Configuration.defaults()
    config = Configuration.merge_shared(defaults, socket.assigns.config)

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:config_form, to_form(config, as: :config))
     |> with_filtered_card_data()
     |> put_flash(:info, config_reload_message(payload[:reason]))}
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
      active_section="card_focus"
      topbar_label="Card Focus"
      topbar_hint="Inspect one issue with a dedicated history and timing view."
    >
      <div class="mx-auto max-w-7xl space-y-6">
        <section class="metrics-card-strong rounded-[2rem] px-6 py-6 sm:px-8">
          <div class="grid gap-6 xl:grid-cols-[minmax(0,1.1fr)_minmax(18rem,0.9fr)] xl:items-end">
            <div class="space-y-4">
              <p class="metrics-eyebrow text-xs uppercase tracking-[0.28em]">Issue deep dive</p>
              <div class="space-y-3">
                <h2 id="card-focus-title" class="metrics-brand metrics-title text-5xl leading-none">
                  Focus one card at a time
                </h2>
                <p class="metrics-copy max-w-3xl text-base leading-7">
                  Start from an issue key, keep the shared YouTrack configuration, and inspect a
                  single card through its state history, delivery timing, collaboration, and change log.
                </p>
              </div>
            </div>

            <div class="metrics-subtle-panel rounded-[1.75rem] p-5">
              <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Current target</p>
              <p id="card-focus-current-issue" class="metrics-title mt-3 text-2xl font-semibold">
                {current_issue_label(@issue_id)}
              </p>
              <p class="metrics-copy mt-2 text-sm leading-6">
                This first slice wires entry and deep-link flow. The next pass will fill these cards
                with live YouTrack-derived history.
              </p>
            </div>
          </div>
        </section>

        <div class="grid gap-6 xl:grid-cols-[minmax(0,1.05fr)_minmax(20rem,0.95fr)]">
          <section class="metrics-card rounded-[2rem] p-6">
            <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Lookup</p>
            <h3 class="metrics-title mt-2 text-2xl font-semibold">Open a card</h3>
            <p class="metrics-copy mt-2 max-w-2xl text-sm leading-6">
              Use an issue key such as PROJ-123. The page accepts direct links and search from here.
            </p>

            <.form
              for={@lookup_form}
              id="card-focus-search-form"
              phx-submit="lookup_card"
              class="mt-5 grid gap-4 md:grid-cols-[minmax(0,1fr)_auto] md:items-end"
            >
              <.input
                field={@lookup_form[:issue_id]}
                id="card-focus-issue-id"
                type="text"
                label="Issue key"
                placeholder="PROJ-123"
              />
              <div class="flex gap-3 md:justify-end">
                <button
                  id="card-focus-open"
                  type="submit"
                  class="metrics-button metrics-button-primary h-11 px-5 text-sm font-semibold"
                >
                  Open card
                </button>
              </div>
            </.form>

            <%= if @lookup_error do %>
              <div class="metrics-subtle-panel mt-4 rounded-2xl p-4">
                <p id="card-focus-lookup-error" class="metrics-title text-sm font-semibold">
                  {@lookup_error}
                </p>
              </div>
            <% end %>

            <div class="mt-6 flex flex-wrap gap-3">
              <button
                :if={@issue_id}
                id="card-focus-fetch"
                type="button"
                phx-click="fetch_card"
                class="metrics-button metrics-button-primary px-5 text-sm font-semibold"
              >
                Load insights
              </button>
              <button
                :if={@issue_id}
                id="card-focus-refresh"
                type="button"
                phx-click="fetch_card"
                phx-value-refresh="true"
                class="metrics-button metrics-button-ghost px-5 text-sm font-semibold"
              >
                Refresh
              </button>
              <button
                id="reload-card-config"
                type="button"
                phx-click="reload_config"
                class="metrics-button metrics-button-ghost px-5 text-sm font-semibold"
              >
                Reload config
              </button>
              <button
                id="clear-card-cache"
                type="button"
                phx-click="clear_cache"
                class="metrics-button metrics-button-ghost px-5 text-sm font-semibold"
              >
                Clear cache
              </button>
            </div>

            <%= if @card_data == nil do %>
              <div class="mt-6 grid gap-4 md:grid-cols-2">
                <.insight_stub_card
                  id="card-focus-state-timeline"
                  title="State timeline"
                  summary="Gantt-like transitions, cycle time, net active time, and inactive interruptions."
                />
                <.insight_stub_card
                  id="card-focus-collaboration"
                  title="Collaboration"
                  summary="Assignee changes, comments added, and description edits over time."
                />
                <.insight_stub_card
                  id="card-focus-tags"
                  title="Tag evolution"
                  summary="Added and removed tags, blocked windows, and rework markers on one issue history axis."
                />
                <.insight_stub_card
                  id="card-focus-breakdown"
                  title="Time breakdown"
                  summary="Time-in-state totals and the active share of the full cycle time."
                />
              </div>
            <% end %>
          </section>

          <aside class="space-y-6">
            <section class="metrics-card rounded-[2rem] p-6">
              <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Fetch state</p>
              <div class="metrics-copy mt-4 space-y-4 text-sm leading-6">
                <%= if @loading? do %>
                  <div id="card-focus-loading" class="metrics-subtle-panel rounded-2xl p-4">
                    Loading issue history for {@issue_id}.
                  </div>
                <% else %>
                  <div class="metrics-subtle-panel rounded-2xl p-4">
                    History fetched
                  </div>
                <% end %>

                <%= if @fetch_error do %>
                  <div id="card-focus-error" class="metrics-subtle-panel rounded-2xl p-4">
                    {@fetch_error}
                  </div>
                <% end %>

                <%= if @fetch_cache_state do %>
                  <div id="card-focus-cache-state" class="metrics-subtle-panel rounded-2xl p-4">
                    {freshness_label(@fetch_cache_state)}
                  </div>
                <% end %>
              </div>
            </section>
          </aside>
        </div>

        <%= if @card_data do %>
          <% timeline_card_data = @filtered_card_data || @card_data %>
          <section id="card-focus-summary" class="space-y-6">
            <div class="metrics-card rounded-[2rem] p-6 space-y-5">
              <div class="flex flex-wrap items-start justify-between gap-4">
                <div class="space-y-2">
                  <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Issue snapshot</p>
                  <h3 class="metrics-title text-3xl font-semibold">
                    {@card_data.issue.issue_key} · {@card_data.issue.title}
                  </h3>
                  <p id="card-focus-issue-meta" class="metrics-copy text-sm leading-6">
                    {@card_data.issue.project} · {@card_data.issue.type || "Unknown type"} ·
                    {@card_data.issue.state || "Unknown state"}
                  </p>
                </div>
                <div class="flex flex-wrap items-center gap-2">
                  <span class="metrics-pill metrics-pill-success px-3 py-2 text-xs uppercase tracking-[0.16em]">
                    {@card_data.issue.status}
                  </span>
                  <.link
                    id="card-focus-compare-link"
                    navigate={~p"/compare?ids=#{@card_data.issue.issue_key}"}
                    class="metrics-pill metrics-pill-muted px-3 py-2 text-xs uppercase tracking-[0.16em] hover:opacity-80 transition-opacity"
                  >
                    Compare
                  </.link>
                </div>
              </div>

              <div class="flex flex-wrap gap-2">
                <%= for stream <- @card_data.issue.workstreams do %>
                  <span class="metrics-pill metrics-pill-accent px-3 py-2 normal-case tracking-normal text-xs">
                    {stream}
                  </span>
                <% end %>
                <%= for assignee <- @card_data.issue.assignees do %>
                  <span class="metrics-pill metrics-pill-muted px-3 py-2 normal-case tracking-normal text-xs">
                    {assignee}
                  </span>
                <% end %>
              </div>

              <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
                <.metric_card id="card-focus-metric-cycle" label="Cycle time" value={format_duration(@card_data.metrics.cycle_time_ms)} />
                <.metric_card id="card-focus-metric-active" label="Net active" value={format_duration(@card_data.metrics.net_active_time_ms)} />
                <.metric_card id="card-focus-metric-inactive" label="Inactive" value={format_duration(@card_data.metrics.inactive_time_ms)} />
                <.metric_card id="card-focus-metric-ratio" label="Active ratio" value={format_ratio(@card_data.metrics.active_ratio_pct)} />
                <.metric_card id="card-focus-metric-comments" label="Comments" value={Integer.to_string(@card_data.metrics.comment_count)} />
                <.metric_card id="card-focus-metric-rework" label="Rework" value={Integer.to_string(@card_data.metrics.rework_count)} />
              </div>

              <div id="card-focus-state-timeline" class="space-y-4">
                <div class="flex items-center justify-between gap-4">
                  <div>
                    <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Timeline</p>
                    <p class="metrics-title mt-1 text-lg font-semibold">State transition Gantt</p>
                  </div>
                  <p class="metrics-copy text-sm leading-6">
                    Created {format_timestamp(@card_data.issue.created)}
                  </p>
                </div>

                <div id="card-focus-timeline-filters" class="flex flex-wrap items-center gap-2">
                  <button
                    id="card-focus-toggle-exclude-todo"
                    type="button"
                    phx-click="toggle_exclude_todo"
                    aria-pressed={to_string(@exclude_todo?)}
                    class={[
                      "metrics-button rounded-full px-4 py-2 text-xs font-semibold uppercase tracking-[0.14em] transition",
                      @exclude_todo? && "metrics-button-primary",
                      !@exclude_todo? && "metrics-button-ghost"
                    ]}
                  >
                    Exclude Todo
                  </button>

                  <button
                    id="card-focus-toggle-exclude-no-sprint"
                    type="button"
                    phx-click="toggle_exclude_no_sprint"
                    aria-pressed={to_string(@exclude_no_sprint?)}
                    class={[
                      "metrics-button rounded-full px-4 py-2 text-xs font-semibold uppercase tracking-[0.14em] transition",
                      @exclude_no_sprint? && "metrics-button-primary",
                      !@exclude_no_sprint? && "metrics-button-ghost"
                    ]}
                  >
                    Exclude No Sprint
                  </button>
                </div>

                <.chart_card
                  id="card-focus-state-gantt"
                  title="State & activity timeline"
                  description="Gantt view of state transitions, active periods, and interruptions."
                  spec={CardFocusCharts.state_timeline_spec(timeline_card_data)}
                  class="h-80"
                  wrapper_class="p-4"
                />

                <div class="grid gap-3 md:grid-cols-2">
                  <%= for segment <- timeline_card_data.active_segments do %>
                    <div class="metrics-subtle-panel rounded-2xl p-3">
                      <p class="metrics-title text-sm font-semibold">{segment.label}</p>
                      <p class="metrics-copy mt-1 text-xs leading-5">
                        {format_duration(segment.duration_ms)} · {format_timestamp(segment.start_ms)} → {format_timestamp(segment.end_ms)}
                      </p>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>

            <div class="grid gap-6 xl:grid-cols-2">
              <section id="card-focus-time-in-state" class="metrics-card rounded-[2rem] p-6">
                <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Time in state</p>
                <div class="mt-4 space-y-4">
                  <%= for state <- @card_data.time_in_state do %>
                    <div>
                      <div class="flex items-center justify-between gap-4">
                        <p class="metrics-title text-sm font-semibold">{state.state}</p>
                        <p class="metrics-copy text-xs leading-5">{format_duration(state.duration_ms)}</p>
                      </div>
                      <div class="mt-2 h-2 rounded-full bg-[color:color-mix(in_oklab,var(--metrics-text)_8%,transparent)]">
                        <div class="h-2 rounded-full bg-[color:var(--metrics-accent)]" style={segment_style(state_width_pct(state.duration_ms, @card_data.metrics.cycle_time_ms))}></div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </section>

              <section class="metrics-card rounded-[2rem] p-6">
                <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Tags on card</p>
                <div class="mt-4 flex flex-wrap gap-2">
                  <%= for tag <- @card_data.issue.tags do %>
                    <span class="metrics-pill metrics-pill-muted px-3 py-2 normal-case tracking-normal text-xs">
                      {tag}
                    </span>
                  <% end %>
                </div>
              </section>
            </div>
          </section>

          <div class="grid gap-6 xl:grid-cols-2">
            <.event_panel id="card-focus-state-events" title="State transitions" empty_text="No state changes found.">
              <:event :for={event <- @card_data.state_events}>
                <div class="metrics-subtle-panel rounded-2xl p-4">
                  <p class="metrics-title text-sm font-semibold">{event_value(event.from)} → {event_value(event.to)}</p>
                  <p class="metrics-copy mt-1 text-xs leading-5">{event.author} · {format_timestamp(event.timestamp)}</p>
                </div>
              </:event>
            </.event_panel>

            <.event_panel id="card-focus-assignee-events" title="Assignee changes" empty_text="No assignee changes found.">
              <:event :for={event <- @card_data.assignee_events}>
                <div class="metrics-subtle-panel rounded-2xl p-4">
                  <p class="metrics-title text-sm font-semibold">{event_value(event.from)} → {event_value(event.to)}</p>
                  <p class="metrics-copy mt-1 text-xs leading-5">{event.author} · {format_timestamp(event.timestamp)}</p>
                </div>
              </:event>
            </.event_panel>

            <.event_panel id="card-focus-comments" title="Comments added" empty_text="No comments found.">
              <:event :for={event <- @card_data.comment_events}>
                <div class="metrics-subtle-panel rounded-2xl p-4">
                  <p class="metrics-title text-sm font-semibold">{event.author}</p>
                  <p class="metrics-copy mt-1 text-xs leading-5">{format_timestamp(event.timestamp)}</p>
                  <p class="metrics-copy mt-3 text-sm leading-6">{truncate_text(event.text)}</p>
                </div>
              </:event>
            </.event_panel>

            <.event_panel id="card-focus-tag-events" title="Tag changes" empty_text="No tag changes found.">
              <:event :for={event <- @card_data.tag_events}>
                <div class="metrics-subtle-panel rounded-2xl p-4">
                  <p class="metrics-title text-sm font-semibold">+ {event_value(event.added)} · - {event_value(event.removed)}</p>
                  <p class="metrics-copy mt-1 text-xs leading-5">{event.author} · {format_timestamp(event.timestamp)}</p>
                </div>
              </:event>
            </.event_panel>

            <.event_panel id="card-focus-description-events" title="Description changes" empty_text="No description changes found.">
              <:event :for={event <- @card_data.description_events}>
                <div class="metrics-subtle-panel rounded-2xl p-4">
                  <p class="metrics-title text-sm font-semibold">{event.change_type}</p>
                  <p class="metrics-copy mt-1 text-xs leading-5">{event.author} · {format_timestamp(event.timestamp)}</p>
                  <p class="metrics-copy mt-3 text-sm leading-6">{truncate_text(event.new_excerpt || event.previous_excerpt)}</p>
                </div>
              </:event>
            </.event_panel>

            <.event_panel id="card-focus-rework-events" title="Rework and reopen" empty_text="No rework events found.">
              <:event :for={event <- @card_data.rework_events}>
                <div class="metrics-subtle-panel rounded-2xl p-4">
                  <p class="metrics-title text-sm font-semibold">{event_value(event.from)} → {event_value(event.to)}</p>
                  <p class="metrics-copy mt-1 text-xs leading-5">{event.author} · {format_timestamp(event.timestamp)}</p>
                </div>
              </:event>
            </.event_panel>
          </div>

          <section id="card-focus-timeline" class="metrics-card rounded-[2rem] p-6">
            <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Unified event timeline</p>
            <div class="mt-4 grid gap-3 lg:grid-cols-2">
              <%= for event <- @card_data.timeline_events do %>
                <div class="metrics-subtle-panel rounded-2xl p-4">
                  <div class="flex items-center justify-between gap-4">
                    <p class="metrics-title text-sm font-semibold">{timeline_event_title(event)}</p>
                    <p class="metrics-copy text-xs leading-5">{format_timestamp(event.timestamp)}</p>
                  </div>
                  <p class="metrics-copy mt-2 text-sm leading-6">{timeline_event_summary(event)}</p>
                </div>
              <% end %>
            </div>
          </section>
        <% end %>
      </div>
    </Layouts.dashboard>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp metric_card(assigns) do
    ~H"""
    <div id={@id} class="metrics-subtle-panel rounded-[1.5rem] p-4">
      <p class="metrics-copy text-xs uppercase tracking-[0.24em]">{@label}</p>
      <p class="metrics-title mt-3 text-2xl font-semibold">{@value}</p>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:summary, :string, required: true)

  defp insight_stub_card(assigns) do
    ~H"""
    <div id={@id} class="metrics-subtle-panel rounded-[1.5rem] p-4">
      <p class="metrics-title text-lg font-semibold">{@title}</p>
      <p class="metrics-copy mt-2 text-sm leading-6">{@summary}</p>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:empty_text, :string, required: true)
  slot(:event)

  defp event_panel(assigns) do
    ~H"""
    <section id={@id} class="metrics-card rounded-[2rem] p-6">
      <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Signal</p>
      <h3 class="metrics-title mt-2 text-xl font-semibold">{@title}</h3>
      <div class="mt-4 space-y-3">
        <%= if @event == [] do %>
          <div class="metrics-subtle-panel rounded-2xl p-4">
            <p class="metrics-copy text-sm leading-6">{@empty_text}</p>
          </div>
        <% else %>
          {render_slot(@event)}
        <% end %>
      </div>
    </section>
    """
  end

  defp normalize_issue_id(nil), do: nil

  defp normalize_issue_id(issue_id) when is_binary(issue_id) do
    issue_id
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp current_issue_label(nil), do: "No card selected"
  defp current_issue_label(issue_id), do: issue_id

  defp page_title(nil), do: "Card Focus"
  defp page_title(issue_id), do: "Card Focus · #{issue_id}"

  defp config_reload_message({:file_change, _paths}),
    do: "Configuration changed on disk and was reloaded"

  defp config_reload_message(:manual), do: "Configuration reloaded"
  defp config_reload_message(_), do: "Configuration updated"

  defp validate_fetch(config, issue_id) do
    cond do
      blank?(issue_id) -> {:error, "Issue ID is required"}
      blank?(config["base_url"]) -> {:error, "Base URL is required"}
      blank?(config["token"]) -> {:error, "Token is required"}
      true -> :ok
    end
  end

  defp start_fetch_task(socket, config, issue_id, refresh?) do
    task =
      Task.Supervisor.async_nolink(YoutrackWeb.TaskSupervisor, fn ->
        fetch_card_data(config, issue_id, refresh?)
      end)

    assign(socket, :fetch_task_ref, task.ref)
  end

  defp fetch_card_data(config, issue_id, refresh?) do
    base_url = String.trim(config["base_url"] || "")
    token = String.trim(config["token"] || "")
    state_field = String.trim(config["state_field"] || "State")
    assignees_field = String.trim(config["assignees_field"] || "Assignee")
    done_names = csv_list(config["done_state_names"])
    in_progress_names = csv_list(config["in_progress_names"])
    inactive_names = csv_list(config["report_inactive_states"])
    sprint_field = String.trim(config["sprint_field"] || "Sprint")
    include_substreams? = parse_bool(config["include_substreams"])
    workstreams_path = String.trim(config["workstreams_path"] || "")

    rules = load_rules(workstreams_path)
    req = Client.new!(base_url, token)

    {:ok, issue, issue_cache_state} =
      YoutrackWeb.FetchCache.get_or_fetch(
        {:card_focus_issue, base_url, issue_id},
        fn -> fetch_issue!(req, issue_id) end,
        refresh: refresh?
      )

    {:ok, activities, activities_cache_state} =
      YoutrackWeb.FetchCache.get_or_fetch(
        {:card_focus_activities, base_url, issue["id"]},
        fn ->
          Client.fetch_activities!(req, issue["id"], categories: @activity_categories)
        end,
        refresh: refresh?
      )

    workstreams =
      Workstreams.streams_for_issue(issue, rules, include_substreams: include_substreams?)

    card_data =
      CardFocus.build(
        issue,
        activities,
        state_field: state_field,
        assignees_field: assignees_field,
        in_progress_names: default_if_empty(in_progress_names, ["In Progress"]),
        inactive_names: default_if_empty(inactive_names, ["To Do", "Todo"]),
        done_names: default_if_empty(done_names, ["Done", "Won't Do"]),
        sprint_field: sprint_field,
        hold_tags: ["on hold", "blocked"],
        workstreams: workstreams
      )

    {:ok,
     %{
       card_data: card_data,
       fetch_cache_state: merge_cache_states(issue_cache_state, activities_cache_state)
     }}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp fetch_issue!(req, issue_id) do
    ["id: #{issue_id}", issue_id]
    |> Enum.find_value(fn query ->
      req
      |> Client.fetch_issues!(query, fields: @issue_fields, top: 5)
      |> Enum.find(fn issue -> issue["idReadable"] == issue_id end)
    end)
    |> case do
      nil -> raise "Issue not found: #{issue_id}"
      issue -> issue
    end
  end

  defp load_rules(""), do: WorkstreamsLoader.empty_rules()

  defp load_rules(path) do
    case WorkstreamsLoader.load_file(path) do
      {:ok, rules} -> rules
      {:error, _reason} -> WorkstreamsLoader.empty_rules()
    end
  end

  defp default_if_empty([], fallback), do: fallback
  defp default_if_empty(values, _fallback), do: values

  defp merge_cache_states(left, right) do
    fetched_at_ms = max(left.fetched_at_ms || 0, right.fetched_at_ms || 0)
    expires_at_ms = max(left.expires_at_ms || 0, right.expires_at_ms || 0)

    %{
      source: merge_cache_source(left.source, right.source),
      fetched_at_ms: fetched_at_ms,
      expires_at_ms: expires_at_ms
    }
  end

  defp merge_cache_source(:refresh, _other), do: :refresh
  defp merge_cache_source(_other, :refresh), do: :refresh
  defp merge_cache_source(:miss, _other), do: :miss
  defp merge_cache_source(_other, :miss), do: :miss
  defp merge_cache_source(_left, _right), do: :hit

  defp freshness_label(cache_state) do
    source_key = if is_map(cache_state), do: Map.get(cache_state, :source), else: cache_state

    source =
      case source_key do
        :hit -> "cache hit"
        :miss -> "cache miss"
        :refresh -> "refresh"
        _ -> "unknown"
      end

    "Last fetch source: #{source}"
  end

  defp segment_style(width_pct), do: "width: #{max(width_pct, 4.0)}%"

  defp state_width_pct(_duration_ms, nil), do: 0.0
  defp state_width_pct(_duration_ms, 0), do: 0.0

  defp state_width_pct(duration_ms, cycle_time_ms),
    do: Float.round(duration_ms / cycle_time_ms * 100, 1)

  defp format_duration(nil), do: "N/A"
  defp format_duration(duration_ms), do: WeeklyReport.format_duration(duration_ms)

  defp format_ratio(nil), do: "N/A"
  defp format_ratio(value), do: "#{value}%"

  defp format_timestamp(nil), do: "Unknown"

  defp format_timestamp(timestamp_ms) when is_integer(timestamp_ms) do
    timestamp_ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%Y/%m/%d %H:%M")
  end

  defp event_value([]), do: "No value"
  defp event_value(values), do: Enum.join(values, ", ")

  defp truncate_text(nil), do: ""

  defp truncate_text(text) do
    if String.length(text) > 180 do
      String.slice(text, 0, 177) <> "..."
    else
      text
    end
  end

  defp timeline_event_title(%{type: "state_changed"}), do: "State changed"
  defp timeline_event_title(%{type: "assignee_changed"}), do: "Assignee changed"
  defp timeline_event_title(%{type: "tags_changed"}), do: "Tags changed"
  defp timeline_event_title(%{type: "comment_added"}), do: "Comment added"
  defp timeline_event_title(%{type: "description_changed"}), do: "Description changed"
  defp timeline_event_title(%{from: _from, to: _to}), do: "Rework"

  defp timeline_event_summary(%{type: "state_changed"} = event) do
    "#{event.author}: #{event_value(event.from)} → #{event_value(event.to)}"
  end

  defp timeline_event_summary(%{type: "assignee_changed"} = event) do
    "#{event.author}: #{event_value(event.from)} → #{event_value(event.to)}"
  end

  defp timeline_event_summary(%{type: "tags_changed"} = event) do
    "#{event.author}: + #{event_value(event.added)} · - #{event_value(event.removed)}"
  end

  defp timeline_event_summary(%{type: "comment_added"} = event) do
    "#{event.author}: #{truncate_text(event.text)}"
  end

  defp timeline_event_summary(%{type: "description_changed"} = event) do
    "#{event.author}: #{truncate_text(event.new_excerpt || event.previous_excerpt)}"
  end

  defp timeline_event_summary(event) do
    "#{event.author}: #{event_value(event.from)} → #{event_value(event.to)}"
  end

  defp csv_list(nil), do: []

  defp csv_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp csv_list(_value), do: []

  defp parse_bool(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp parse_bool(_value), do: false

  defp with_filtered_card_data(socket) do
    filtered_card_data =
      apply_timeline_filters(
        socket.assigns.card_data,
        socket.assigns.config,
        socket.assigns.exclude_todo?,
        socket.assigns.exclude_no_sprint?
      )

    assign(socket, :filtered_card_data, filtered_card_data)
  end

  defp apply_timeline_filters(nil, _config, _exclude_todo?, _exclude_no_sprint?), do: nil

  defp apply_timeline_filters(card_data, config, exclude_todo?, exclude_no_sprint?) do
    todo_states =
      config
      |> Map.get("report_inactive_states", "To Do,Todo")
      |> csv_list()
      |> default_if_empty(["To Do", "Todo"])
      |> Enum.map(&String.downcase/1)

    filtered_state_segments =
      Enum.filter(card_data.state_segments, fn segment ->
        keep_todo? =
          if exclude_todo? do
            String.downcase(segment.state || "") not in todo_states
          else
            true
          end

        keep_sprint? =
          if exclude_no_sprint? do
            Map.get(segment, :has_sprint?, true)
          else
            true
          end

        keep_todo? and keep_sprint?
      end)

    keep_intervals =
      Enum.map(filtered_state_segments, fn segment ->
        %{start_ms: segment.start_ms, end_ms: segment.end_ms}
      end)

    filtered_active_segments = clip_intervals(card_data.active_segments, keep_intervals)

    %{
      card_data
      | state_segments: filtered_state_segments,
        active_segments: filtered_active_segments
    }
  end

  defp clip_intervals(_segments, []), do: []

  defp clip_intervals(segments, keep_intervals) do
    clipped =
      Enum.flat_map(segments, fn segment ->
        Enum.flat_map(keep_intervals, fn interval ->
          clip_start = max(segment.start_ms, interval.start_ms)
          clip_end = min(segment.end_ms, interval.end_ms)

          if clip_start < clip_end do
            duration_ms = clip_end - clip_start

            [
              segment
              |> Map.put(:start_ms, clip_start)
              |> Map.put(:end_ms, clip_end)
              |> Map.put(:duration_ms, duration_ms)
            ]
          else
            []
          end
        end)
      end)

    total_duration_ms =
      clipped
      |> Enum.reduce(0, fn segment, acc -> acc + segment.duration_ms end)
      |> max(1)

    clipped
    |> Enum.map(fn segment ->
      Map.put(segment, :width_pct, Float.round(segment.duration_ms / total_duration_ms * 100, 1))
    end)
    |> Enum.sort_by(& &1.start_ms)
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
