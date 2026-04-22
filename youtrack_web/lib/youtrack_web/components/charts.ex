defmodule YoutrackWeb.Components.Charts do
  @moduledoc """
  VegaLite chart rendering components.

  Provides a `chart/1` component that wraps the VegaLite JS hook for rendering
  Vega-Lite specifications in Phoenix LiveView templates.
  """

  use Phoenix.Component

  @doc """
  Renders a VegaLite chart using the vega-embed JS hook.

  ## Attributes

  - `id` - Required. Unique identifier for the chart element.
  - `spec` - Required. VegaLite specification as a map or atom referencing a function.
  - `class` - Optional. CSS classes to apply to the chart container.

  ## Example

      <.chart
        id="flow-metrics-throughput"
        spec={@throughput_spec}
        class="h-96"
      />
  """
  attr(:id, :string, required: true)
  attr(:spec, :map, required: true)
  attr(:class, :string, default: "h-96 w-full")

  def chart(assigns) do
    assigns = assign(assigns, :spec_json, Jason.encode!(assigns.spec))

    ~H"""
    <div
      id={@id}
      phx-hook="VegaLite"
      data-spec={@spec_json}
      class={["metrics-chart min-w-0 overflow-hidden", @class]}
    >
      <div class="metrics-chart-loading flex h-full items-center justify-center">
        <span>Loading chart...</span>
      </div>
    </div>
    """
  end

  @doc """
  Renders a chart with a title and optional description.

  Wraps the `chart/1` component with a header section.

  ## Attributes

  - `id` - Required. Unique identifier for the chart.
  - `title` - Required. Title displayed above the chart.
  - `spec` - Required. VegaLite specification.
  - `description` - Optional. Descriptive text shown under the title.
  - `class` - Optional. CSS classes for the chart container.

  ## Example

      <.chart_card
        id="wip-chart"
        title="Work in Progress"
        description="Issues currently in progress by stream"
        spec={@wip_spec}
      />
  """
  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:spec, :map, required: true)
  attr(:description, :string, default: nil)
  attr(:class, :string, default: "h-96")
  attr(:wrapper_class, :string, default: nil)

  def chart_card(assigns) do
    ~H"""
    <details
      id={"#{@id}-card"}
      class={["metrics-card rounded-4xl p-4 group/card overflow-hidden", @wrapper_class]}
      open
      phx-hook=".ChartCollapse"
    >
      <summary class="mb-4 flex cursor-pointer select-none list-none items-center justify-between gap-2">
        <div>
          <h3 class="metrics-title text-lg font-semibold">{@title}</h3>
          <%= if @description do %>
            <p class="metrics-copy mt-1 text-sm">{@description}</p>
          <% end %>
        </div>
        <span class="metrics-copy text-xs transition-transform duration-200 group-open/card:rotate-180">
          ▼
        </span>
      </summary>
      <.chart id={@id} spec={@spec} class={"w-full #{@class}"} />
    </details>
    """
  end

  attr(:items, :list, required: true)
  attr(:title, :string, default: "Charts")

  def chart_toc(assigns) do
    ~H"""
    <details class="metrics-card rounded-[2rem] p-4" open>
      <summary class="metrics-eyebrow cursor-pointer list-none text-sm font-semibold uppercase tracking-[0.22em]">
        {@title}
      </summary>
      <nav aria-label="Chart table of contents" class="mt-4 space-y-2">
        <%= for item <- @items do %>
          <a
            href={"##{item.id}"}
            class="metrics-nav-link metrics-nav-link-idle block rounded-xl border px-3 py-2 text-sm hover:text-[color:var(--metrics-accent)]"
          >
            {item.title}
          </a>
        <% end %>
      </nav>
    </details>
    """
  end

  @doc """
  Renders collapse / show-all controls for chart sections.
  Dispatches a custom DOM event that the `.ChartCollapse` hook handles.
  """
  attr(:target, :string,
    required: true,
    doc: "CSS selector for the container holding collapsible details elements"
  )

  def collapse_controls(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <button
        type="button"
        class="metrics-button metrics-button-ghost px-3 py-1.5 text-xs"
        onclick={"document.querySelectorAll('#{@target} details[phx-hook]').forEach(d => { d.removeAttribute('open'); d.dispatchEvent(new Event('toggle')) })"}
      >
        Collapse all
      </button>
      <button
        type="button"
        class="metrics-button metrics-button-ghost px-3 py-1.5 text-xs"
        onclick={"document.querySelectorAll('#{@target} details[phx-hook]').forEach(d => { d.setAttribute('open',''); d.dispatchEvent(new Event('toggle')) })"}
      >
        Show all
      </button>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChartCollapse">
      const STORAGE_KEY = "youtrack.collapsed_cards"

      function readCollapsed() {
        try {
          return JSON.parse(window.localStorage.getItem(STORAGE_KEY)) || []
        } catch (_) { return [] }
      }

      function writeCollapsed(list) {
        try { window.localStorage.setItem(STORAGE_KEY, JSON.stringify(list)) }
        catch (_) {}
      }

      export default {
        mounted() {
          const id = this.el.id
          const collapsed = readCollapsed()
          if (collapsed.includes(id)) {
            this.el.removeAttribute("open")
          }

          this.el.addEventListener("toggle", () => {
            const list = readCollapsed()
            const isOpen = this.el.open
            if (isOpen) {
              writeCollapsed(list.filter(x => x !== id))
            } else {
              if (!list.includes(id)) {
                writeCollapsed([...list, id])
              }
            }
          })
        }
      }
    </script>
    """
  end

  @doc """
  A generic collapsible section wrapper using `<details>`.
  Persists open/close state via the same `.ChartCollapse` hook.
  """
  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:default_open, :boolean, default: true)
  slot(:inner_block, required: true)

  def collapsible_section(assigns) do
    ~H"""
    <details
      id={@id}
      class={["metrics-card rounded-[2rem] p-6 group/card", @class]}
      open={@default_open}
      phx-hook=".ChartCollapse"
    >
      <summary class="flex cursor-pointer select-none list-none items-center justify-between gap-2">
        <div>
          <%= if @subtitle do %>
            <p class="metrics-copy text-xs uppercase tracking-[0.24em]">{@subtitle}</p>
          <% end %>
          <h3 class="metrics-title mt-2 text-2xl font-semibold">{@title}</h3>
        </div>
        <span class="metrics-copy text-xs transition-transform duration-200 group-open/card:rotate-180">
          ▼
        </span>
      </summary>
      <div class="mt-4">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end
end
