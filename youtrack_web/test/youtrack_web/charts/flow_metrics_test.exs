defmodule YoutrackWeb.Charts.FlowMetricsTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.Charts.FlowMetrics

  test "build_chart_specs/1 returns the expected chart families and optional charts" do
    chart_specs = FlowMetrics.build_chart_specs(sample_inputs())

    assert Map.keys(chart_specs) |> Enum.sort() == [
             :bus_factor,
             :context_switch_avg,
             :context_switch_heatmap,
             :cycle_by_stream,
             :cycle_histogram,
             :cycle_vs_net_active,
             :long_running,
             :net_active_by_stream,
             :net_active_histogram,
             :rework_by_stream,
             :rotation_person_stream,
             :rotation_stream_tenure,
             :rotation_switches,
             :rotation_tenure,
             :throughput,
             :throughput_by_person,
             :unplanned_by_person,
             :unplanned_by_stream,
             :unplanned_trend,
             :wip_by_person,
             :wip_by_stream
           ]

    assert Enum.map(chart_specs.throughput["layer"], & &1["mark"]["type"]) == ["bar", "line"]

    assert chart_specs.cycle_histogram["encoding"]["x"] == %{
             "field" => "cycle_days",
             "type" => "quantitative",
             "bin" => %{"maxbins" => 20},
             "title" => "Cycle Time (days)"
           }

    assert chart_specs.cycle_by_stream["mark"]["type"] == "boxplot"
    assert chart_specs.net_active_by_stream["mark"]["type"] == "boxplot"

    assert chart_specs.context_switch_heatmap["mark"]["type"] == "rect"
    assert chart_specs.context_switch_heatmap["encoding"]["x"]["field"] == "week"
    assert chart_specs.context_switch_heatmap["encoding"]["y"]["field"] == "person"

    assert chart_specs.cycle_vs_net_active["transform"] == [
             %{"fold" => ["cycle_days", "net_active_days"], "as" => ["metric", "days"]}
           ]

    assert chart_specs.rework_by_stream["encoding"]["y"]["field"] == "rework_issues"
  end

  test "omits optional net active and rework charts when the source data is empty" do
    chart_specs =
      sample_inputs()
      |> Map.put(:net_active_data, [])
      |> Map.put(:rework_by_stream, [])
      |> FlowMetrics.build_chart_specs()

    assert is_nil(chart_specs.net_active_histogram)
    assert is_nil(chart_specs.net_active_by_stream)
    assert is_nil(chart_specs.cycle_vs_net_active)
    assert is_nil(chart_specs.rework_by_stream)
  end

  defp sample_inputs do
    %{
      throughput_by_week: [%{week: "2024-06-03", completed: 4}],
      throughput_by_person: [%{person: "Alice", completed: 3}],
      cycle_time_data: [%{issue_id: "PROJ-1", person: "Alice", stream: "Backend", cycle_days: 4.5}],
      net_active_data: [
        %{issue_id: "PROJ-1", person: "Alice", stream: "Backend", cycle_days: 4.5, net_active_days: 3.0}
      ],
      wip_by_person: [%{person: "Alice", wip: 2}],
      wip_by_stream: [%{stream: "Backend", wip: 2}],
      context_switch_avg: [%{person: "Alice", avg_streams: 1.5}],
      context_switch_data: [%{person: "Alice", week: "2024-06-03", distinct_streams: 2}],
      bus_factor_data: [%{stream: "Backend", bus_factor: 2, people: "alice,bob", total_items: 4}],
      long_running: [%{issue_id: "PROJ-9", person: "Alice", stream: "Backend", age_days: 12.0}],
      rotation_metrics: [%{person: "Alice", switches: 1, avg_tenure_weeks: 2.5}],
      rotation_person_stream: [%{person: "Alice", week: "2024-06-03", stream: "Backend"}],
      stream_tenure: [%{person: "Alice", stream: "Backend", total_weeks: 3}],
      rework_by_stream: [%{stream: "Backend", rework_issues: 1, total_reopenings: 2}],
      unplanned_by_stream: [%{stream: "Backend", unplanned: 1}],
      unplanned_by_person: [%{person: "Alice", unplanned: 1}],
      unplanned_trend: [%{week: "2024-06-03", unplanned: 1}]
    }
  end
end