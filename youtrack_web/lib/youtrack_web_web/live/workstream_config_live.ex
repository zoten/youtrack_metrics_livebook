defmodule YoutrackWeb.WorkstreamConfigLive do
  @moduledoc """
  Dedicated page for viewing and editing workstream classification rules.

  Provides:
  - YAML rules editor that saves directly to workstreams.yaml
  - Issue fetching to compute classification statistics
  - Unclassified slugs table with click-through paginated issue list
  - Configuration summary: matched count per rule per workstream
  """

  use YoutrackWeb, :live_view

  alias Youtrack.Client
  alias Youtrack.Workstreams
  alias Youtrack.WorkstreamsLoader
  alias YoutrackWeb.Configuration
  alias YoutrackWeb.ConfigVisibilityPreference
  alias YoutrackWeb.RuntimeConfig

  @page_size 20

  @impl true
  def mount(_params, _session, socket) do
    defaults =
      Configuration.defaults()
      |> Configuration.merge_shared(Configuration.shared_from_socket(socket))

    config_open? = ConfigVisibilityPreference.from_socket(socket)

    {yaml_text, save_path, rules} = load_yaml_and_rules(defaults["workstreams_path"] || "")

    socket =
      socket
      |> assign(:current_scope, nil)
      |> assign(:page_title, "Workstream Config")
      |> assign(:config_open?, config_open?)
      |> assign(:config, defaults)
      |> assign(:config_form, to_form(defaults, as: :config))
      |> assign(:yaml_text, yaml_text)
      |> assign(:yaml_error, nil)
      |> assign(:save_path, save_path)
      |> assign(:rules, rules)
      |> assign(:loading?, false)
      |> assign(:fetch_error, nil)
      |> assign(:fetch_cache_state, nil)
      |> assign(:raw_issues, [])
      |> assign(:unclassified_stats, [])
      |> assign(:match_stats, [])
      |> assign(:selected_slug, nil)
      |> assign(:selected_slug_issues, [])
      |> assign(:slug_page, 1)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(YoutrackWeb.PubSub, "workstreams:updated")
      Phoenix.PubSub.subscribe(YoutrackWeb.PubSub, RuntimeConfig.topic())
    end

    {:ok, socket}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Config panel

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

  # ──────────────────────────────────────────────────────────────────────────
  # YAML editor

  @impl true
  def handle_event("rules_changed", %{"yaml_text" => text}, socket) do
    {:noreply, assign(socket, :yaml_text, text)}
  end

  @impl true
  def handle_event("save_rules", _params, socket) do
    path = socket.assigns.save_path

    case path do
      nil ->
        {:noreply,
         assign(
           socket,
           :yaml_error,
           "No workstreams.yaml path configured. Set WORKSTREAMS_PATH in your .env."
         )}

      path ->
        case WorkstreamsLoader.save_to_file(socket.assigns.yaml_text, path) do
          :ok ->
            rules = reload_rules_from_path(path)
            unclassified_stats = build_unclassified_stats(socket.assigns.raw_issues, rules)
            match_stats = Workstreams.build_match_stats(socket.assigns.raw_issues, rules)

            Phoenix.PubSub.broadcast(
              YoutrackWeb.PubSub,
              "workstreams:updated",
              :workstreams_updated
            )

            {:noreply,
             socket
             |> assign(:yaml_error, nil)
             |> assign(:rules, rules)
             |> assign(:unclassified_stats, unclassified_stats)
             |> assign(:match_stats, match_stats)
             |> assign(:selected_slug, nil)
             |> assign(:selected_slug_issues, [])
             |> assign(:slug_page, 1)
             |> put_flash(:info, "Saved to #{path}")}

          {:error, reason} ->
            {:noreply, assign(socket, :yaml_error, "Save failed: #{reason}")}
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Issue fetch

  @impl true
  def handle_event("fetch_data", params, socket) do
    refresh? = params["refresh"] == "true"

    case validate_config(socket.assigns.config) do
      :ok ->
        {:noreply,
         socket
         |> assign(:loading?, true)
         |> assign(:fetch_error, nil)
         |> start_fetch_task(socket.assigns.config, socket.assigns.rules, refresh?)}

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
        {yaml_text, save_path, rules} = load_yaml_and_rules(defaults["workstreams_path"] || "")

        {:noreply,
         socket
         |> assign(:config, defaults)
         |> assign(:config_form, to_form(defaults, as: :config))
         |> assign(:yaml_text, yaml_text)
         |> assign(:save_path, save_path)
         |> assign(:rules, rules)
         |> assign(:yaml_error, nil)
         |> put_flash(:info, "Reloaded .env and workstreams.yaml")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reload failed: #{reason}")}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Slug classifier

  @impl true
  def handle_event("classify_slug", %{"slug" => slug, "stream" => stream}, socket) do
    case socket.assigns.save_path do
      nil ->
        {:noreply, put_flash(socket, :error, "Cannot save: no workstreams.yaml path configured.")}

      path ->
        case WorkstreamsLoader.add_slug_to_stream(slug, stream, path) do
          {:ok, rules, yaml_string} ->
            unclassified_stats = build_unclassified_stats(socket.assigns.raw_issues, rules)
            match_stats = Workstreams.build_match_stats(socket.assigns.raw_issues, rules)

            Phoenix.PubSub.broadcast(
              YoutrackWeb.PubSub,
              "workstreams:updated",
              :workstreams_updated
            )

            selected_slug = socket.assigns.selected_slug

            selected_slug_issues =
              cond do
                is_nil(selected_slug) -> []
                selected_slug == slug -> []
                true -> socket.assigns.selected_slug_issues
              end

            {:noreply,
             socket
             |> assign(:rules, rules)
             |> assign(:yaml_text, yaml_string)
             |> assign(:yaml_error, nil)
             |> assign(:unclassified_stats, unclassified_stats)
             |> assign(:match_stats, match_stats)
             |> assign(:selected_slug, if(selected_slug == slug, do: nil, else: selected_slug))
             |> assign(:selected_slug_issues, selected_slug_issues)
             |> assign(:slug_page, 1)
             |> put_flash(:info, "\"#{slug}\" → #{stream} saved")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to save: #{reason}")}
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Slug detail pagination

  @impl true
  def handle_event("show_slug_details", %{"slug" => slug}, socket) do
    issues = issues_for_slug(socket.assigns.raw_issues, slug)

    {:noreply,
     socket
     |> assign(:selected_slug, slug)
     |> assign(:selected_slug_issues, issues)
     |> assign(:slug_page, 1)}
  end

  @impl true
  def handle_event("close_slug_details", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_slug, nil)
     |> assign(:selected_slug_issues, [])
     |> assign(:slug_page, 1)}
  end

  @impl true
  def handle_event("next_slug_page", _params, socket) do
    total = length(socket.assigns.selected_slug_issues)
    max_page = max(ceil(total / @page_size), 1)
    new_page = min(socket.assigns.slug_page + 1, max_page)
    {:noreply, assign(socket, :slug_page, new_page)}
  end

  @impl true
  def handle_event("prev_slug_page", _params, socket) do
    new_page = max(socket.assigns.slug_page - 1, 1)
    {:noreply, assign(socket, :slug_page, new_page)}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Async task results

  @impl true
  def handle_info({ref, {:ok, result}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:raw_issues, result.raw_issues)
     |> assign(:unclassified_stats, result.unclassified_stats)
     |> assign(:match_stats, result.match_stats)
     |> assign(:fetch_cache_state, result.fetch_cache_state)
     |> assign(:selected_slug, nil)
     |> assign(:selected_slug_issues, [])
     |> assign(:slug_page, 1)}
  end

  @impl true
  def handle_info({ref, {:error, reason}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:fetch_error, "Fetch failed: #{reason}")}
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
    # Another view triggered an update — reload rules from disk, keep issues
    {yaml_text, save_path, rules} =
      load_yaml_and_rules(socket.assigns.config["workstreams_path"] || "")

    unclassified_stats = build_unclassified_stats(socket.assigns.raw_issues, rules)
    match_stats = Workstreams.build_match_stats(socket.assigns.raw_issues, rules)

    {:noreply,
     socket
     |> assign(:yaml_text, yaml_text)
     |> assign(:save_path, save_path)
     |> assign(:rules, rules)
     |> assign(:yaml_error, nil)
     |> assign(:unclassified_stats, unclassified_stats)
     |> assign(:match_stats, match_stats)}
  end

  @impl true
  def handle_info({:config_reloaded, payload}, socket) do
    defaults = Configuration.defaults()
    config = Configuration.merge_shared(defaults, socket.assigns.config)

    {yaml_text, save_path, rules} = load_yaml_and_rules(config["workstreams_path"] || "")

    unclassified_stats = build_unclassified_stats(socket.assigns.raw_issues, rules)
    match_stats = Workstreams.build_match_stats(socket.assigns.raw_issues, rules)

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:config_form, to_form(config, as: :config))
     |> assign(:yaml_text, yaml_text)
     |> assign(:save_path, save_path)
     |> assign(:rules, rules)
     |> assign(:yaml_error, nil)
     |> assign(:unclassified_stats, unclassified_stats)
     |> assign(:match_stats, match_stats)
     |> put_flash(:info, config_reload_message(payload[:reason]))}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_scope}
      config={@config}
      config_form={@config_form}
      config_open?={@config_open?}
      active_section="workstream_config"
      freshness={@fetch_cache_state}
      topbar_label="Workstream Config"
      topbar_hint="Edit workstream rules, classify untracked slugs, review match coverage"
    >
      <div class="space-y-6 p-6 pb-20">
        <%!-- Config toggle bar --%>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <button
            id="wsc-toggle-config"
            type="button"
            phx-click="toggle_config"
            class="metrics-button metrics-button-ghost px-4 py-2 text-sm"
          >
            {if @config_open?, do: "Hide config", else: "Show config"}
          </button>

          <div class="flex flex-wrap gap-2">
            <button
              id="wsc-fetch-data"
              type="button"
              phx-click="fetch_data"
              class="metrics-button metrics-button-primary font-semibold"
            >
              Fetch (cache)
            </button>
            <button
              id="wsc-fetch-data-refresh"
              type="button"
              phx-click="fetch_data"
              phx-value-refresh="true"
              class="metrics-button metrics-button-secondary"
            >
              Refresh (API)
            </button>
            <button
              id="wsc-reload-config"
              type="button"
              phx-click="reload_config"
              class="metrics-button metrics-button-secondary"
            >
              Reload .env
            </button>
            <button
              id="wsc-clear-cache"
              type="button"
              phx-click="clear_cache"
              class="metrics-button metrics-button-ghost"
            >
              Clear cache
            </button>
          </div>
        </div>

        <%= if @fetch_cache_state do %>
          <p id="wsc-cache-state" class="metrics-eyebrow text-xs uppercase tracking-[0.2em]">
            Last fetch: {cache_state_label(@fetch_cache_state)}
          </p>
        <% end %>

        <%!-- Error banner --%>
        <%= if @fetch_error do %>
          <div class="metrics-card rounded-[2rem] border border-red-400/30 bg-red-500/10 p-5 text-red-200">
            {@fetch_error}
          </div>
        <% end %>

        <%!-- Loading indicator --%>
        <%= if @loading? do %>
          <div class="metrics-card metrics-copy rounded-[2rem] p-10 text-center">
            <div class="metrics-spinner mx-auto mb-4 h-10 w-10 animate-spin rounded-full border-4">
            </div>
            Fetching and classifying issues…
          </div>
        <% end %>

        <%!-- Stats row --%>
        <div class="metrics-grid">
          <.stat_card label="Fetched issues" value={to_string(length(@raw_issues))} tone="neutral" />
          <.stat_card
            label="Unclassified slugs"
            value={to_string(length(@unclassified_stats))}
            tone="warning"
          />
          <.stat_card
            label="Matched rules"
            value={to_string(length(@match_stats))}
            tone="success"
          />
        </div>

        <%!-- YAML Rules editor --%>
        <.collapsible_section
          id="wsc-yaml-editor"
          title="Workstream Rules"
          subtitle="YAML configuration"
        >
          <div class="space-y-3">
            <%= if @save_path do %>
              <p class="metrics-copy text-xs">
                Editing:
                <span class="metrics-code text-[color:var(--metrics-accent)]">{@save_path}</span>
              </p>
            <% else %>
              <p class="metrics-copy text-xs text-yellow-400">
                No workstreams.yaml path found. Set WORKSTREAMS_PATH in your .env to enable saving.
              </p>
            <% end %>

            <textarea
              id="wsc-yaml-textarea"
              name="yaml_text"
              phx-change="rules_changed"
              class="metrics-form-control w-full rounded-3xl p-4 font-mono text-xs"
              rows="20"
            >{@yaml_text}</textarea>

            <%= if @yaml_error do %>
              <p class="rounded-2xl border border-red-400/30 bg-red-500/10 px-4 py-2 text-sm text-red-300">
                {@yaml_error}
              </p>
            <% end %>

            <div class="flex gap-2">
              <button
                id="wsc-save-rules"
                type="button"
                phx-click="save_rules"
                class="metrics-button metrics-button-primary px-4 py-2 text-sm font-semibold"
                disabled={is_nil(@save_path)}
              >
                Save to file
              </button>
            </div>
          </div>
        </.collapsible_section>

        <%!-- Unclassified slugs --%>
        <%= if @unclassified_stats != [] do %>
          <.collapsible_section id="wsc-unclassified" title="Unclassified Slugs" subtitle="Classifier">
            <div class="space-y-3">
              <%= for row <- @unclassified_stats do %>
                <div
                  id={"wsc-slug-row-#{row.slug}"}
                  class="metrics-subtle-panel rounded-2xl p-3 space-y-3"
                >
                  <%!-- Header row: slug info + classify form --%>
                  <.form
                    for={%{}}
                    as={:classify}
                    phx-submit="classify_slug"
                    class="grid grid-cols-1 gap-2 md:grid-cols-[minmax(0,1fr)_12rem_8rem_8rem] md:items-center"
                  >
                    <input type="hidden" name="slug" value={row.slug} />
                    <div class="metrics-title text-sm">
                      <span class="font-semibold text-[color:var(--metrics-accent)]">{row.slug}</span>
                      <span class="metrics-copy ml-2">({row.count} issues)</span>
                    </div>
                    <select name="stream" class="metrics-form-control rounded-lg px-2 py-2 text-sm">
                      <%= for stream <- stream_options(@rules) do %>
                        <option value={stream}>{stream}</option>
                      <% end %>
                    </select>
                    <button
                      type="submit"
                      class="metrics-button metrics-button-primary px-3 py-2 text-sm font-semibold"
                    >
                      Apply
                    </button>
                    <button
                      type="button"
                      phx-click={
                        if @selected_slug == row.slug,
                          do: "close_slug_details",
                          else: "show_slug_details"
                      }
                      phx-value-slug={row.slug}
                      class="metrics-button metrics-button-ghost px-3 py-2 text-sm"
                    >
                      {if @selected_slug == row.slug, do: "Hide", else: "View issues"}
                    </button>
                  </.form>

                  <%!-- Paginated issue table for selected slug --%>
                  <%= if @selected_slug == row.slug do %>
                    <.slug_issues_table
                      issues={@selected_slug_issues}
                      page={@slug_page}
                      page_size={20}
                    />
                  <% end %>
                </div>
              <% end %>
            </div>
          </.collapsible_section>
        <% end %>

        <%!-- Configuration summary --%>
        <%= if @match_stats != [] do %>
          <.collapsible_section
            id="wsc-match-summary"
            title="Configuration Summary"
            subtitle="Match coverage"
          >
            <div class="overflow-x-auto rounded-2xl">
              <table class="w-full text-sm">
                <thead>
                  <tr class="metrics-copy border-b border-white/10 text-left text-xs uppercase tracking-[0.2em]">
                    <th class="py-3 pr-4">Workstream</th>
                    <th class="py-3 pr-4">Rule Type</th>
                    <th class="py-3 pr-4">Rule Value</th>
                    <th class="py-3 text-right">Issues Matched</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-white/5">
                  <%= for stat <- @match_stats do %>
                    <tr class="metrics-title">
                      <td class="py-2 pr-4 font-semibold text-[color:var(--metrics-accent)]">
                        {stat.stream}
                      </td>
                      <td class="py-2 pr-4 metrics-copy">
                        <span class="metrics-pill metrics-pill-muted px-2 py-0.5 text-xs capitalize">
                          {stat.rule_type}
                        </span>
                      </td>
                      <td class="metrics-code py-2 pr-4 text-xs">{stat.rule_value}</td>
                      <td class="py-2 text-right tabular-nums">{stat.count}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </.collapsible_section>
        <% end %>
      </div>
    </Layouts.dashboard>
    """
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Sub-components

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

  attr(:issues, :list, required: true)
  attr(:page, :integer, required: true)
  attr(:page_size, :integer, required: true)

  defp slug_issues_table(assigns) do
    total = length(assigns.issues)
    max_page = max(ceil(total / assigns.page_size), 1)

    page_issues =
      Enum.slice(assigns.issues, (assigns.page - 1) * assigns.page_size, assigns.page_size)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:max_page, max_page)
      |> assign(:page_issues, page_issues)

    ~H"""
    <div class="space-y-3 pt-2">
      <div class="overflow-x-auto rounded-2xl border border-white/10">
        <table class="w-full text-sm">
          <thead>
            <tr class="metrics-copy border-b border-white/10 text-left text-xs uppercase tracking-[0.2em]">
              <th class="py-2 pl-4 pr-6 w-28">ID</th>
              <th class="py-2 pr-4">Title</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-white/5">
            <%= for issue <- @page_issues do %>
              <tr class="metrics-title">
                <td class="metrics-code py-2 pl-4 pr-6 text-xs text-[color:var(--metrics-accent)] w-28">
                  {issue.id}
                </td>
                <td class="metrics-copy py-2 pr-4 text-sm">{issue.title}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="flex items-center justify-between text-xs metrics-copy">
        <span>{@total} issue{if @total == 1, do: "", else: "s"} · Page {@page} of {@max_page}</span>
        <div class="flex gap-2">
          <button
            type="button"
            phx-click="prev_slug_page"
            disabled={@page <= 1}
            class="metrics-button metrics-button-ghost px-3 py-1 text-xs disabled:opacity-40"
          >
            ← Prev
          </button>
          <button
            type="button"
            phx-click="next_slug_page"
            disabled={@page >= @max_page}
            class="metrics-button metrics-button-ghost px-3 py-1 text-xs disabled:opacity-40"
          >
            Next →
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Stat card CSS helpers

  defp stat_card_classes("accent"), do: "metrics-pill-accent"
  defp stat_card_classes("success"), do: "metrics-pill-success"
  defp stat_card_classes("warning"), do: "metrics-button-secondary"
  defp stat_card_classes(_), do: "metrics-pill-muted"

  # ──────────────────────────────────────────────────────────────────────────
  # Task / async

  defp start_fetch_task(socket, config, rules, refresh?) do
    task =
      Task.Supervisor.async_nolink(YoutrackWeb.TaskSupervisor, fn ->
        fetch_and_classify(config, rules, refresh?)
      end)

    assign(socket, :fetch_task_ref, task.ref)
  end

  defp fetch_and_classify(config, rules, refresh?) do
    base_url = String.trim(config["base_url"] || "")
    token = String.trim(config["token"] || "")
    base_query = String.trim(config["base_query"] || "")
    days_back = parse_int(config["days_back"], 90)

    today = Date.utc_today() |> Date.to_iso8601()
    start_date = Date.utc_today() |> Date.add(-days_back) |> Date.to_iso8601()
    query = "#{base_query} updated: #{start_date} .. #{today}"

    req = Client.new!(base_url, token)
    cache_key = {:workstream_issues, base_url, query}

    {:ok, raw_issues, cache_state} =
      YoutrackWeb.FetchCache.get_or_fetch(
        cache_key,
        fn -> Client.fetch_issues!(req, query) end,
        refresh: refresh?
      )

    {:ok,
     %{
       raw_issues: raw_issues,
       unclassified_stats: build_unclassified_stats(raw_issues, rules),
       match_stats: Workstreams.build_match_stats(raw_issues, rules),
       fetch_cache_state: cache_state
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Data helpers

  defp build_unclassified_stats(issues, rules) do
    issues
    |> Enum.filter(fn issue ->
      Workstreams.streams_for_issue(issue, rules, include_substreams: false) == ["(unclassified)"]
    end)
    |> Enum.group_by(fn issue ->
      issue["summary"]
      |> Workstreams.summary_slug()
      |> Workstreams.normalize_slug()
      |> case do
        nil -> "(no slug)"
        value -> value
      end
    end)
    |> Enum.map(fn {slug, rows} -> %{slug: slug, count: length(rows)} end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp issues_for_slug(raw_issues, slug) do
    raw_issues
    |> Enum.filter(fn issue ->
      extracted =
        issue["summary"]
        |> Workstreams.summary_slug()
        |> Workstreams.normalize_slug()
        |> case do
          nil -> "(no slug)"
          value -> value
        end

      extracted == slug
    end)
    |> Enum.map(fn issue ->
      %{
        id: issue["idReadable"] || issue["id"] || "–",
        title: issue["summary"] || "–"
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp load_yaml_and_rules("") do
    case WorkstreamsLoader.load_raw_from_default_paths() do
      {:ok, yaml_text, path} ->
        rules = WorkstreamsLoader.load_file!(path)
        {yaml_text, path, rules}

      {:error, _} ->
        {"", nil, WorkstreamsLoader.empty_rules()}
    end
  end

  defp load_yaml_and_rules(path) when is_binary(path) do
    case WorkstreamsLoader.load_file_raw(path) do
      {:ok, yaml_text} ->
        rules = WorkstreamsLoader.load_file!(path)
        {yaml_text, path, rules}

      {:error, _} ->
        {"", path, WorkstreamsLoader.empty_rules()}
    end
  end

  defp reload_rules_from_path(path) do
    case WorkstreamsLoader.load_file(path) do
      {:ok, rules} -> rules
      {:error, _} -> WorkstreamsLoader.empty_rules()
    end
  end

  defp stream_options(rules) do
    rules.slug_prefix_to_stream
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp validate_config(config) do
    cond do
      blank?(config["base_url"]) -> {:error, "Base URL is required"}
      blank?(config["token"]) -> {:error, "Token is required"}
      blank?(config["base_query"]) -> {:error, "Base query is required"}
      true -> :ok
    end
  end

  defp cache_state_label(:hit), do: "cache hit"
  defp cache_state_label(:miss), do: "cache miss"
  defp cache_state_label(:refresh), do: "refresh"
  defp cache_state_label(%{source: source}), do: cache_state_label(source)
  defp cache_state_label(_), do: "unknown"

  defp config_reload_message({:file_change, _paths}),
    do: "Configuration changed on disk and was reloaded"

  defp config_reload_message(:manual), do: "Configuration reloaded"
  defp config_reload_message(_), do: "Configuration updated"

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default
end
