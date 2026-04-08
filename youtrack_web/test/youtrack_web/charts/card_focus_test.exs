defmodule YoutrackWeb.Charts.CardFocusTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.Charts.CardFocus

  test "state_timeline_spec/1 builds state and activity layers with independent color scales" do
    card_data = %{
      state_segments: [
        %{state: "Backlog", start_ms: 1_000, end_ms: 2_000, duration_ms: 1_000},
        %{state: "In Progress", start_ms: 2_000, end_ms: 5_000, duration_ms: 3_000}
      ],
      active_segments: [
        %{label: "Active", start_ms: 2_000, end_ms: 4_000, duration_ms: 2_000},
        %{label: "On Hold", start_ms: 4_000, end_ms: 5_000, duration_ms: 1_000}
      ]
    }

    spec = CardFocus.state_timeline_spec(card_data)

    assert spec["$schema"] == "https://vega.github.io/schema/vega-lite/v5.json"
    assert spec["height"] == 160
    assert length(spec["layer"]) == 2

    [state_layer, activity_layer] = spec["layer"]

    assert state_layer["mark"]["type"] == "bar"
    assert state_layer["encoding"]["x"]["field"] == "start"
    assert state_layer["encoding"]["x2"]["field"] == "end"

    assert activity_layer["mark"]["type"] == "bar"

    assert activity_layer["encoding"]["color"]["scale"]["domain"] == [
             "Active",
             "On Hold"
           ]

    assert activity_layer["encoding"]["color"]["scale"]["range"] == [
             "#10b981",
             "#ef4444"
           ]

    assert spec["resolve"] == %{"scale" => %{"color" => "independent"}}
  end
end