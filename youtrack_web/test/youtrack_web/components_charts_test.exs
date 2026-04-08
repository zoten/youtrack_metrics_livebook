defmodule YoutrackWeb.ComponentsChartsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias YoutrackWeb.Components.Charts

  test "chart/1 renders the VegaLite hook and encoded spec" do
    spec = %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "mark" => "bar",
      "data" => %{"values" => [%{"x" => 1}]}
    }

    html =
      render_component(&Charts.chart/1,
        id: "chart-throughput",
        spec: spec,
        class: "h-80"
      )

    assert html =~ "id=\"chart-throughput\""
    assert html =~ "phx-hook=\"VegaLite\""
    assert html =~ "data-spec="
    assert html =~ "metrics-chart"
    assert html =~ "Loading chart..."
  end

  test "chart_card/1 renders collapsible wrapper and nested chart" do
    spec = %{"$schema" => "https://vega.github.io/schema/vega-lite/v5.json", "mark" => "bar"}

    html =
      render_component(&Charts.chart_card/1,
        id: "pairing-matrix",
        title: "Pair Matrix",
        description: "Collaboration heatmap",
        spec: spec
      )

    assert html =~ "id=\"pairing-matrix-card\""
    assert html =~ "phx-hook=\"YoutrackWeb.Components.Charts.ChartCollapse\""
    assert html =~ "Pair Matrix"
    assert html =~ "Collaboration heatmap"
    assert html =~ "id=\"pairing-matrix\""
    assert html =~ "phx-hook=\"VegaLite\""
  end

  test "chart_toc/1 renders anchor links for all items" do
    html =
      render_component(&Charts.chart_toc/1,
        title: "Flow Charts",
        items: [
          %{id: "chart-throughput", title: "Throughput"},
          %{id: "chart-wip", title: "WIP"}
        ]
      )

    assert html =~ "Flow Charts"
    assert html =~ "href=\"#chart-throughput\""
    assert html =~ "href=\"#chart-wip\""
    assert html =~ "Throughput"
    assert html =~ "WIP"
  end
end