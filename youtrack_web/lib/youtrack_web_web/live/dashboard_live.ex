defmodule YoutrackWeb.DashboardLive do
  use YoutrackWeb, :live_view

  alias YoutrackWeb.Configuration
  alias YoutrackWeb.ChartSpecs

  @impl true
  def mount(_params, _session, socket) do
    defaults = Configuration.defaults()

    {:ok,
     socket
     |> assign(:current_scope, nil)
     |> assign(:config_open?, true)
     |> assign(:page_title, "YouTrack Metrics")
     |> assign(:config, defaults)
     |> assign(:config_form, to_form(defaults, as: :config))
     |> assign(:sections, Configuration.sections())
     |> assign(:current_section, Configuration.section("flow_metrics"))
     # Add sample charts for display
     |> assign(:sample_bar_spec, ChartSpecs.sample_bar_chart())
     |> assign(:sample_line_spec, ChartSpecs.sample_line_chart())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    section = Configuration.section(Map.get(params, "section", "flow_metrics"))

    {:noreply, assign(socket, :current_section, section)}
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
                  A Phoenix shell for the livebooks, using the same shared `youtrack/` library,
                  workstream rules, and local-first configuration.
                </p>
              </div>
            </div>

            <nav aria-label="Dashboard sections" class="space-y-2">
              <%= for section <- @sections do %>
                <.link
                  id={"nav-#{section.id}"}
                  patch={~p"/?section=#{section.id}"}
                  aria-current={if(@current_section.id == section.id, do: "page", else: nil)}
                  class={[
                    "metrics-link block rounded-3xl border px-4 py-3",
                    if(@current_section.id == section.id,
                      do: "border-orange-300/60 bg-orange-300/12 text-stone-50",
                      else: "border-white/8 bg-white/3 text-stone-300 hover:border-orange-200/30 hover:bg-white/6"
                    )
                  ]}
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
              <div class="flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
                <div class="max-w-3xl space-y-4">
                  <p class="text-xs uppercase tracking-[0.28em] text-orange-200/70">
                    Section currently being wired
                  </p>
                  <div class="space-y-3">
                    <h2 id="current-section-title" class="metrics-brand text-5xl leading-none text-stone-50">
                      {@current_section.label}
                    </h2>
                    <p class="max-w-2xl text-base leading-7 text-stone-300">
                      {@current_section.description}
                    </p>
                  </div>
                </div>

                <div class="metrics-grid w-full lg:max-w-2xl">
                  <.stat_card label="Visual scope" value={@current_section.visuals} tone="accent" />
                  <.stat_card label="Shared source" value="youtrack/ library" tone="neutral" />
                  <.stat_card label="State" value={@current_section.stage} tone="success" />
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
                  <p class="text-xs uppercase tracking-[0.24em] text-stone-400">Sample visualization</p>
                  <h3 class="mt-2 text-xl font-semibold text-stone-50 mb-4">VegaLite integration test</h3>
                  <.chart
                    id="sample-bar-chart"
                    spec={@sample_bar_spec}
                    class="h-72"
                  />
                </section>

                <section class="metrics-card rounded-[2rem] p-6">
                  <p class="text-xs uppercase tracking-[0.24em] text-stone-400">Current slice</p>
                  <h3 class="mt-2 text-2xl font-semibold text-stone-50">What this section will expose</h3>
                  <div class="mt-5 flex flex-wrap gap-3">
                    <%= for highlight <- @current_section.highlights do %>
                      <span class="rounded-full border border-orange-200/20 bg-orange-200/8 px-3 py-2 text-sm text-orange-100">
                        {highlight}
                      </span>
                    <% end %>
                  </div>
                </section>
              </div>

              <aside class="space-y-6">
                <section class="metrics-card rounded-[2rem] p-6">
                  <p class="text-xs uppercase tracking-[0.24em] text-stone-400">Implementation notes</p>
                  <ul class="mt-4 space-y-3 text-sm leading-6 text-stone-300">
                    <li>Shared runtime defaults are now read from environment variables and exposed to LiveView.</li>
                    <li>The Phoenix shell has replaced the default landing page and routes directly to a dashboard LiveView.</li>
                    <li>The next slice is wiring the first section to real `youtrack/` fetch pipelines and VegaLite specs.</li>
                  </ul>
                </section>

                <section class="metrics-card rounded-[2rem] p-6">
                  <p class="text-xs uppercase tracking-[0.24em] text-stone-400">Preview</p>
                  <h3 class="mt-2 text-xl font-semibold text-stone-50">Config snapshot</h3>
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
end
