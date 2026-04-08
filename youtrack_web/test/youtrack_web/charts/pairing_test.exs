defmodule YoutrackWeb.Charts.PairingTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.Charts.Pairing

  test "build_chart_specs/1 returns the expected pairing chart families" do
    pair_records = [
      %{
        person_a: "Alice",
        person_b: "Bob",
        workstream: "Backend",
        is_unplanned: false,
        project: "PROJ",
        issue_id: "PROJ-1",
        created: 1_717_286_400_000,
        created_date: ~D[2024-06-02]
      },
      %{
        person_a: "Alice",
        person_b: "Carol",
        workstream: "Frontend",
        is_unplanned: true,
        project: "OPS",
        issue_id: "OPS-2",
        created: 1_717_545_600_000,
        created_date: ~D[2024-06-05]
      }
    ]

    chart_specs = Pairing.build_chart_specs(pair_records)

    assert Map.keys(chart_specs) |> Enum.sort() == [
             :firefighter_pair,
             :firefighter_person,
             :interrupt_aggregate,
             :interrupt_person,
             :involvement_by_person,
             :pair_matrix,
             :pairing_by_project,
             :pairing_by_workstream,
             :pairing_trend,
             :planned_unplanned,
             :top_pairs
           ]

    assert chart_specs.pair_matrix["mark"]["type"] == "rect"
    assert chart_specs.pair_matrix["encoding"]["x"]["field"] == "person_a"
    assert chart_specs.pair_matrix["encoding"]["y"]["field"] == "person_b"

    assert Enum.map(chart_specs.pairing_trend["layer"], & &1["mark"]["type"]) == ["bar", "line"]

    assert chart_specs.planned_unplanned["encoding"]["color"]["scale"] == %{
             "domain" => ["Planned", "Unplanned"],
             "range" => ["steelblue", "orangered"]
           }

    assert chart_specs.pairing_by_project["encoding"]["x"]["sort"] == "-y"
    assert chart_specs.pairing_by_project["encoding"]["y"]["field"] == "pair_count"
  end
end