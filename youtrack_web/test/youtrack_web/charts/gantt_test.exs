defmodule YoutrackWeb.Charts.GanttTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.Charts.Gantt

  test "build_chart_specs/1 returns the expected top-level gantt and summary charts" do
    work_items = [
      %{
        issue_id: "PROJ-1",
        title: "Planned backend work",
        person_name: "Alice",
        stream: "Backend",
        status: "finished",
        is_unplanned: false,
        created: 1_717_286_400_000,
        start_at: 1_717_286_400_000,
        end_at: 1_717_372_800_000
      },
      %{
        issue_id: "PROJ-2",
        title: "Investigate outage",
        person_name: "Bob",
        stream: "(unclassified)",
        status: "ongoing",
        is_unplanned: true,
        created: 1_717_545_600_000,
        start_at: 1_717_545_600_000,
        end_at: 1_717_632_000_000
      }
    ]

    chart_specs = Gantt.build_chart_specs(work_items)

    assert Map.keys(chart_specs) |> Enum.sort() == [
             :gantt,
             :interrupts_monthday,
             :interrupts_weekday,
             :planned_unplanned,
             :unclassified_slug,
             :unplanned_person,
             :unplanned_stream
           ]

    assert chart_specs.gantt["facet"]["row"]["field"] == "person_name"

    assert chart_specs.gantt["spec"]["encoding"]["color"]["scale"] == %{
             "domain" => ["planned", "unplanned"],
             "range" => ["steelblue", "orangered"]
           }

    assert chart_specs.planned_unplanned["encoding"]["color"]["scale"] == %{
             "domain" => ["Planned", "Unplanned"],
             "range" => ["steelblue", "orangered"]
           }

    assert chart_specs.interrupts_weekday["encoding"]["x"]["sort"] == [
             "Mon",
             "Tue",
             "Wed",
             "Thu",
             "Fri",
             "Sat",
             "Sun"
           ]

    assert chart_specs.unclassified_slug["encoding"]["x"]["sort"] == "-y"
  end
end