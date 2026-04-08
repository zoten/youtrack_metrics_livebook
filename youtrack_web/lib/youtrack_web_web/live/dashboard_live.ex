defmodule YoutrackWeb.DashboardLive do
  use YoutrackWeb, :live_view

  alias YoutrackWeb.Configuration
  alias YoutrackWeb.ConfigVisibilityPreference

  @impl true
  def mount(_params, _session, socket) do
    defaults =
      Configuration.defaults()
      |> Configuration.merge_shared(Configuration.shared_from_socket(socket))

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
    config = Configuration.merge_shared(socket.assigns.config, params)

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:config_form, to_form(config, as: :config))}
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
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_scope}
      config={@config}
      config_form={@config_form}
      config_open?={@config_open?}
      topbar_label="Dashboard"
      topbar_hint="Overview of your team's key metrics at a glance."
    >
      <div class="mx-auto max-w-7xl space-y-6">
        <div class="metrics-card-strong rounded-[2rem] px-6 py-6 sm:px-8">
          <div class="grid gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(18rem,0.8fr)] xl:items-end">
            <div class="max-w-3xl space-y-5">
              <p class="metrics-eyebrow text-xs uppercase tracking-[0.28em]">
                Dashboard home
              </p>
              <div class="space-y-3">
                <h2
                  id="dashboard-home-title"
                  class="metrics-brand metrics-title text-5xl leading-none"
                >
                  Choose a live workflow
                </h2>
                <p class="metrics-copy max-w-2xl text-base leading-7">
                  The scaffold is gone. Each route below opens a working LiveView that can fetch,
                  compute, and render actual YouTrack-backed results with the shared configuration
                  shown on this page.
                </p>
              </div>

              <div class="flex flex-wrap gap-2">
                <span class="metrics-pill metrics-pill-accent">
                  Shared defaults
                </span>
                <span class="metrics-pill metrics-pill-muted">
                  Real routes
                </span>
                <span class="metrics-pill metrics-pill-success">
                  Ready sections
                </span>
              </div>
            </div>

            <div class="space-y-4">
              <div class="metrics-subtle-panel rounded-[1.75rem] p-5">
                <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Fast path</p>
                <ol class="metrics-title mt-4 space-y-3 text-sm leading-6">
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
              <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Sections</p>
              <h3 class="metrics-title mt-2 text-2xl font-semibold">Open a live view</h3>
              <p class="metrics-copy mt-2 max-w-2xl text-sm leading-6">
                These cards are direct entry points, not placeholders. Open the page that matches
                the decision you need to make.
              </p>
              <div class="mt-5 grid gap-4 md:grid-cols-2">
                <%= for section <- @sections do %>
                  <div class="metrics-subtle-panel rounded-[1.5rem] p-4 transition hover:border-[color:color-mix(in_oklab,var(--metrics-accent)_30%,transparent)] hover:bg-[color:color-mix(in_oklab,var(--metrics-text)_7%,transparent)]">
                    <div class="flex items-start justify-between gap-4">
                      <div>
                        <h4 class="metrics-title text-lg font-semibold">{section.label}</h4>
                        <p class="metrics-eyebrow mt-1 text-xs uppercase tracking-[0.2em]">
                          {section.visuals}
                        </p>
                        <p class="metrics-copy mt-2 text-sm leading-6">{section.description}</p>
                      </div>
                      <span class="metrics-pill metrics-pill-success px-2 py-1 text-[11px]">
                        {section.stage}
                      </span>
                    </div>
                    <div class="mt-4 flex flex-wrap gap-2">
                      <%= for highlight <- section.highlights do %>
                        <span class="metrics-pill metrics-pill-accent px-3 py-2 normal-case tracking-normal text-xs">
                          {highlight}
                        </span>
                      <% end %>
                    </div>
                    <.link
                      id={"open-#{section.id}"}
                      navigate={section_path(section.id)}
                      class="metrics-button metrics-button-primary mt-5 text-sm font-semibold"
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
              <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Working model</p>
              <div class="metrics-copy mt-4 space-y-4 text-sm leading-6">
                <div class="metrics-subtle-panel rounded-2xl p-4">
                  Defaults are loaded from environment variables and prefilled into every section form.
                </div>
                <div class="metrics-subtle-panel rounded-2xl p-4">
                  This page is intentionally narrow: choose a route here, do the actual analysis there.
                </div>
                <div class="metrics-subtle-panel rounded-2xl p-4">
                  Section pages own the real fetch, cache, chart, and report flows against YouTrack data.
                </div>
              </div>
            </section>

            <section class="metrics-card rounded-[2rem] p-6">
              <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Preview</p>
              <h3 class="metrics-title mt-2 text-xl font-semibold">Effective config snapshot</h3>
              <div class="metrics-code metrics-code-panel mt-4 overflow-x-auto rounded-3xl p-4 text-xs leading-6">
                <pre>{Jason.encode_to_iodata!(@config, pretty: true)}</pre>
              </div>
            </section>
          </aside>
        </div>
      </div>
    </Layouts.dashboard>
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
      <p class="metrics-stat-label text-xs uppercase tracking-[0.22em]">{@label}</p>
      <p class="metrics-stat-value mt-3 text-xl font-semibold">{@value}</p>
    </div>
    """
  end

  defp stat_card_classes("accent"), do: "metrics-pill-accent"
  defp stat_card_classes("success"), do: "metrics-pill-success"
  defp stat_card_classes(_tone), do: "metrics-pill-muted"

  defp section_path("flow_metrics"), do: ~p"/flow-metrics"
  defp section_path("gantt"), do: ~p"/gantt"
  defp section_path("pairing"), do: ~p"/pairing"
  defp section_path("weekly_report"), do: ~p"/weekly-report"
  defp section_path(_), do: ~p"/flow-metrics"
end
