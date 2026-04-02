defmodule YoutrackWeb.DashboardLive do
  use YoutrackWeb, :live_view

  alias YoutrackWeb.Configuration
  alias YoutrackWeb.ConfigVisibilityPreference

  @impl true
  def mount(_params, _session, socket) do
    defaults = Configuration.defaults()
    config_open? = ConfigVisibilityPreference.from_socket(socket)

    {:ok,
     socket
     |> assign(:current_scope, nil)
     |> assign(:config_open?, config_open?)
     |> assign(:page_title, "YouTrack Metrics")
     |> assign(:config, defaults)
     |> assign(:config_form, to_form(defaults, as: :config))
     |> assign(:sections, Configuration.sections())}
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
  def handle_event("chart_rendered", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("chart_error", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="metrics-shell">
        <aside class="metrics-sidebar px-5 py-6 sm:px-6">
          <div class="space-y-6">
            <div class="space-y-3">
              <p class="text-xs uppercase tracking-[0.28em] text-orange-200/70">Local cockpit</p>
              <div class="space-y-2">
                <h1 class="metrics-brand text-4xl leading-none text-stone-50">YouTrack Metrics</h1>
                <p class="max-w-xs text-sm leading-6 text-stone-300">
                  One shared control surface for the live YouTrack views: keep defaults here,
                  then jump into the section that answers the question you actually have.
                </p>
              </div>
            </div>

            <nav aria-label="Dashboard sections" class="space-y-2">
              <%= for section <- @sections do %>
                <.link
                  id={"nav-#{section.id}"}
                  navigate={section_path(section.id)}
                  class="metrics-link block rounded-3xl border border-white/8 bg-white/3 px-4 py-3 text-stone-300 hover:border-orange-200/30 hover:bg-white/6"
                >
                  <div class="flex items-start justify-between gap-4">
                    <div>
                      <p class="text-sm font-semibold">{section.label}</p>
                      <p class="mt-1 text-xs uppercase tracking-[0.2em] text-stone-400">
                        {section.visuals}
                      </p>
                    </div>
                    <span class="rounded-full border border-emerald-300/20 bg-emerald-300/10 px-2 py-1 text-[11px] uppercase tracking-[0.18em] text-emerald-200">
                      {section.stage}
                    </span>
                  </div>
                </.link>
              <% end %>
            </nav>

            <div class="metrics-card rounded-3xl p-4">
              <p class="text-xs uppercase tracking-[0.24em] text-stone-400">Shared paths</p>
              <dl class="mt-3 space-y-3 text-sm text-stone-200">
                <div>
                  <dt class="text-stone-400">Workstreams</dt>
                  <dd class="metrics-code mt-1 text-xs text-orange-100">
                    {@config["workstreams_path"]}
                  </dd>
                </div>
                <div>
                  <dt class="text-stone-400">Prompts</dt>
                  <dd class="metrics-code mt-1 text-xs text-orange-100">
                    {@config["prompts_path"]}
                  </dd>
                </div>
              </dl>
            </div>
          </div>
        </aside>

        <section class="metrics-content">
          <div class="mx-auto max-w-7xl space-y-6">
            <div class="metrics-card-strong rounded-[2rem] px-6 py-6 sm:px-8">
              <div class="grid gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(18rem,0.8fr)] xl:items-end">
                <div class="max-w-3xl space-y-5">
                  <p class="text-xs uppercase tracking-[0.28em] text-orange-200/70">
                    Dashboard home
                  </p>
                  <div class="space-y-3">
                    <h2 id="dashboard-home-title" class="metrics-brand text-5xl leading-none text-stone-50">
                      Choose a live workflow
                    </h2>
                    <p class="max-w-2xl text-base leading-7 text-stone-300">
                      The scaffold is gone. Each route below opens a working LiveView that can fetch,
                      compute, and render actual YouTrack-backed results with the shared configuration
                      shown on this page.
                    </p>
                  </div>

                  <div class="flex flex-wrap gap-2">
                    <span class="rounded-full border border-orange-200/20 bg-orange-200/10 px-3 py-2 text-xs uppercase tracking-[0.18em] text-orange-100">
                      Shared defaults
                    </span>
                    <span class="rounded-full border border-white/10 bg-white/6 px-3 py-2 text-xs uppercase tracking-[0.18em] text-stone-200">
                      Real routes
                    </span>
                    <span class="rounded-full border border-emerald-300/20 bg-emerald-300/10 px-3 py-2 text-xs uppercase tracking-[0.18em] text-emerald-200">
                      Ready sections
                    </span>
                  </div>
                </div>

                <div class="space-y-4">
                  <div class="rounded-[1.75rem] border border-white/10 bg-black/15 p-5">
                    <p class="text-xs uppercase tracking-[0.24em] text-stone-400">Fast path</p>
                    <ol class="mt-4 space-y-3 text-sm leading-6 text-stone-200">
                      <li>Review shared paths and environment-backed defaults.</li>
                      <li>Pick the page that matches the analysis you need.</li>
                      <li>Run the fetch/build action there to render real data.</li>
                    </ol>
                  </div>

                  <div class="metrics-grid w-full">
                  <.stat_card label="Sections" value={to_string(length(@sections))} tone="accent" />
                  <.stat_card label="Shared source" value="youtrack/ library" tone="neutral" />
                    <.stat_card label="Entry state" value="Operational" tone="success" />
                  </div>
                </div>
              </div>
            </div>

            <div class="grid gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(20rem,0.8fr)]">
              <div class="space-y-6">
                <section class="metrics-card rounded-[2rem] p-6">
                  <div class="flex items-center justify-between gap-4">
                    <div>
                      <p class="text-xs uppercase tracking-[0.24em] text-stone-400">Shared configuration</p>
                      <h3 class="mt-2 text-2xl font-semibold text-stone-50">
                        Live defaults, same sources
                      </h3>
                    </div>
                    <button
                      id="toggle-shared-config"
                      type="button"
                      phx-click="toggle_config"
                      class="rounded-full border border-white/10 px-4 py-2 text-xs font-semibold uppercase tracking-[0.2em] text-stone-200 transition hover:border-orange-200/40 hover:bg-white/6"
                    >
                      <%= if @config_open? do %>
                        Collapse
                      <% else %>
                        Expand
                      <% end %>
                    </button>
                  </div>

                  <%= if @config_open? do %>
                    <.form
                      for={@config_form}
                      id="shared-config-form"
                      phx-change="config_changed"
                      class="mt-6 grid gap-4 md:grid-cols-2"
                    >
                      <.input field={@config_form[:base_url]} type="text" label="Base URL" />
                      <.input field={@config_form[:token]} type="password" label="Token" />
                      <.input field={@config_form[:base_query]} type="text" label="Base query" />
                      <.input field={@config_form[:days_back]} type="number" label="Days back" />
                      <.input field={@config_form[:state_field]} type="text" label="State field" />
                      <.input field={@config_form[:assignees_field]} type="text" label="Assignees field" />
                      <.input field={@config_form[:project_prefix]} type="text" label="Project prefix" />
                      <.input field={@config_form[:excluded_logins]} type="text" label="Excluded logins" />
                      <.input field={@config_form[:in_progress_names]} type="text" label="In progress names" />
                      <.input field={@config_form[:done_state_names]} type="text" label="Done state names" />
                      <.input field={@config_form[:unplanned_tag]} type="text" label="Unplanned tag" />
                      <.input
                        field={@config_form[:use_activities]}
                        type="select"
                        label="Use activities"
                        options={[{"Yes", "true"}, {"No", "false"}]}
                      />
                      <.input
                        field={@config_form[:include_substreams]}
                        type="select"
                        label="Include substreams"
                        options={[{"Yes", "true"}, {"No", "false"}]}
                      />
                      <.input field={@config_form[:workstreams_path]} type="text" label="Workstreams path" />
                      <.input field={@config_form[:prompts_path]} type="text" label="Prompts path" />
                    </.form>
                  <% end %>
                </section>

                <section class="metrics-card rounded-[2rem] p-6">
                  <p class="text-xs uppercase tracking-[0.24em] text-stone-400">Sections</p>
                  <h3 class="mt-2 text-2xl font-semibold text-stone-50">Open a live view</h3>
                  <p class="mt-2 max-w-2xl text-sm leading-6 text-stone-300">
                    These cards are direct entry points, not placeholders. Open the page that matches
                    the decision you need to make.
                  </p>
                  <div class="mt-5 grid gap-4 md:grid-cols-2">
                    <%= for section <- @sections do %>
                      <div class="rounded-[1.5rem] border border-white/10 bg-white/5 p-4 transition hover:border-orange-200/30 hover:bg-white/7">
                        <div class="flex items-start justify-between gap-4">
                          <div>
                            <h4 class="text-lg font-semibold text-stone-50">{section.label}</h4>
                            <p class="mt-1 text-xs uppercase tracking-[0.2em] text-orange-200/70">
                              {section.visuals}
                            </p>
                            <p class="mt-2 text-sm leading-6 text-stone-300">{section.description}</p>
                          </div>
                          <span class="rounded-full border border-emerald-300/20 bg-emerald-300/10 px-2 py-1 text-[11px] uppercase tracking-[0.18em] text-emerald-200">
                            {section.stage}
                          </span>
                        </div>
                        <div class="mt-4 flex flex-wrap gap-2">
                          <%= for highlight <- section.highlights do %>
                            <span class="rounded-full border border-orange-200/20 bg-orange-200/8 px-3 py-2 text-xs text-orange-100">
                              {highlight}
                            </span>
                          <% end %>
                        </div>
                        <.link
                          id={"open-#{section.id}"}
                          navigate={section_path(section.id)}
                          class="mt-5 inline-flex rounded-lg bg-orange-400 px-4 py-2 text-sm font-semibold text-stone-950 hover:bg-orange-300"
                        >
                          Open {section.label}
                        </.link>
                      </div>
                    <% end %>
                  </div>
                </section>
              </div>

              <aside class="space-y-6">
                <section class="metrics-card rounded-[2rem] p-6">
                  <p class="text-xs uppercase tracking-[0.24em] text-stone-400">Working model</p>
                  <div class="mt-4 space-y-4 text-sm leading-6 text-stone-300">
                    <div class="rounded-2xl border border-white/8 bg-white/4 p-4">
                      Defaults are loaded from environment variables and prefilled into every section form.
                    </div>
                    <div class="rounded-2xl border border-white/8 bg-white/4 p-4">
                      This page is intentionally narrow: choose a route here, do the actual analysis there.
                    </div>
                    <div class="rounded-2xl border border-white/8 bg-white/4 p-4">
                      Section pages own the real fetch, cache, chart, and report flows against YouTrack data.
                    </div>
                  </div>
                </section>

                <section class="metrics-card rounded-[2rem] p-6">
                  <p class="text-xs uppercase tracking-[0.24em] text-stone-400">Preview</p>
                  <h3 class="mt-2 text-xl font-semibold text-stone-50">Effective config snapshot</h3>
                  <div class="metrics-code mt-4 overflow-x-auto rounded-3xl border border-white/8 bg-black/20 p-4 text-xs leading-6 text-orange-100">
                    <pre>{Jason.encode_to_iodata!(@config, pretty: true)}</pre>
                  </div>
                </section>
              </aside>
            </div>
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
    <div class={[
      "rounded-[1.5rem] border px-4 py-4",
      stat_card_classes(@tone)
    ]}>
      <p class="text-xs uppercase tracking-[0.22em] text-stone-400">{@label}</p>
      <p class="mt-3 text-xl font-semibold text-stone-50">{@value}</p>
    </div>
    """
  end

  defp stat_card_classes("accent"), do: "border-orange-200/30 bg-orange-200/10"
  defp stat_card_classes("success"), do: "border-emerald-200/25 bg-emerald-200/10"
  defp stat_card_classes(_tone), do: "border-white/10 bg-white/5"

  defp section_path("flow_metrics"), do: ~p"/flow-metrics"
  defp section_path("gantt"), do: ~p"/gantt"
  defp section_path("pairing"), do: ~p"/pairing"
  defp section_path("weekly_report"), do: ~p"/weekly-report"
  defp section_path(_), do: ~p"/flow-metrics"
end
