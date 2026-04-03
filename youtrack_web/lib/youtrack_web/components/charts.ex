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
      class={["metrics-chart", @class]}
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
    <div class={["metrics-card rounded-4xl p-4", @wrapper_class]}>
      <div class="mb-4">
        <h3 class="metrics-title text-lg font-semibold">{@title}</h3>
          <%= if @description do %>
            <p class="metrics-copy mt-1 text-sm">{@description}</p>
          <% end %>
      </div>
      <.chart id={@id} spec={@spec} class={"w-full #{@class}"} />
    </div>
    """
  end

  attr(:items, :list, required: true)
  attr(:title, :string, default: "Charts")

  def chart_toc(assigns) do
    ~H"""
    <details class="metrics-card rounded-[2rem] p-4 lg:sticky lg:top-6" open>
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
end
