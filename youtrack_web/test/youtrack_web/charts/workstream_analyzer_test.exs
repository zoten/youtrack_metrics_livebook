defmodule YoutrackWeb.Charts.WorkstreamAnalyzerTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.Charts.WorkstreamAnalyzer

  test "build_chart_specs/1 returns compare and composition chart families" do
    inputs = %{
      compare_series: [
        %{stream: "Backend", week: "2024-06-03", effort: 3.0},
        %{stream: "Frontend", week: "2024-06-03", effort: 2.0}
      ],
      composition_series: [
        %{substream: "(direct)", week: "2024-06-03", effort: 3.0},
        %{substream: "API", week: "2024-06-03", effort: 2.0}
      ],
      composition_totals: [
        %{week: "2024-06-03", total_effort: 5.0}
      ]
    }

    chart_specs = WorkstreamAnalyzer.build_chart_specs(inputs)

    assert Map.keys(chart_specs) |> Enum.sort() == [:compare_effort, :composition_effort]

    compare_layers = chart_specs.compare_effort["layer"]
    assert Enum.map(compare_layers, & &1["mark"]["type"]) == ["area", "line"]

    composition_layers = chart_specs.composition_effort["layer"]
    assert Enum.map(composition_layers, & &1["mark"]["type"]) == ["area", "line"]

    assert hd(compare_layers)["encoding"]["color"]["field"] == "stream"
    assert hd(composition_layers)["encoding"]["color"]["field"] == "substream"
  end

  test "build_chart_specs/1 omits empty chart families" do
    specs =
      WorkstreamAnalyzer.build_chart_specs(%{
        compare_series: [],
        composition_series: [],
        composition_totals: []
      })

    assert is_nil(specs.compare_effort)
    assert is_nil(specs.composition_effort)
  end
end
