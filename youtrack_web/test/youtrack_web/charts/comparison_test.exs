defmodule YoutrackWeb.Charts.ComparisonTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.Charts.Comparison

  test "shared_timeline_spec/1 builds faceted layered gantt for multiple cards" do
    cards = [
      %{
        issue_id: "PROJ-10",
        issue_order: 1,
        card_data: %{
          issue: %{issue_key: "PROJ-10"},
          state_segments: [
            %{state: "Backlog", start_ms: 1_000, end_ms: 2_000, duration_ms: 1_000},
            %{state: "In Progress", start_ms: 2_000, end_ms: 6_000, duration_ms: 4_000}
          ],
          active_segments: [
            %{label: "Active", start_ms: 2_000, end_ms: 5_000, duration_ms: 3_000}
          ]
        }
      },
      %{
        issue_id: "PROJ-11",
        issue_order: 2,
        card_data: %{
          issue: %{issue_key: "PROJ-11"},
          state_segments: [
            %{state: "In Progress", start_ms: 3_000, end_ms: 7_000, duration_ms: 4_000}
          ],
          active_segments: [
            %{label: "On Hold", start_ms: 5_000, end_ms: 6_000, duration_ms: 1_000}
          ]
        }
      }
    ]

    spec = Comparison.shared_timeline_spec(cards)

    assert spec["$schema"] == "https://vega.github.io/schema/vega-lite/v5.json"
    assert spec["facet"]["row"]["field"] == "issue_key"

    assert spec["facet"]["row"]["sort"] == %{
             "field" => "issue_order",
             "op" => "min",
             "order" => "ascending"
           }

    assert spec["spec"]["height"] == 74
    assert spec["spec"]["resolve"] == %{"scale" => %{"color" => "independent"}}

    [state_layer, activity_layer] = spec["spec"]["layer"]

    assert state_layer["transform"] == [%{"filter" => "datum.track === 'State'"}]
    assert activity_layer["transform"] == [%{"filter" => "datum.track === 'Activity'"}]

    assert state_layer["encoding"]["color"]["legend"]["title"] == "State"
    assert activity_layer["encoding"]["color"]["legend"]["title"] == "Activity"

    labels = spec["data"]["values"] |> Enum.map(& &1["issue_key"]) |> Enum.uniq() |> Enum.sort()
    assert labels == ["PROJ-10", "PROJ-11"]
  end

  test "event timeline specs build faceted point charts for state changes, comments, and tags" do
    cards = [
      %{
        issue_id: "PROJ-10",
        issue_order: 1,
        card_data: %{
          issue: %{issue_key: "PROJ-10"},
          state_segments: [],
          active_segments: [],
          state_events: [
            %{timestamp: 2_000, author: "Alice", from: ["To Do"], to: ["In Progress"]}
          ],
          comment_events: [
            %{timestamp: 3_000, author: "Bob", text: "Working on it"}
          ],
          tag_events: [
            %{timestamp: 4_000, author: "Bob", added: ["blocked"], removed: []}
          ]
        }
      },
      %{
        issue_id: "PROJ-11",
        issue_order: 2,
        card_data: %{
          issue: %{issue_key: "PROJ-11"},
          state_segments: [],
          active_segments: [],
          state_events: [],
          comment_events: [],
          tag_events: [
            %{timestamp: 5_000, author: "Cara", added: [], removed: ["blocked"]}
          ]
        }
      }
    ]

    state_spec = Comparison.state_events_timeline_spec(cards)
    comment_spec = Comparison.comment_timeline_spec(cards)
    tag_spec = Comparison.tag_timeline_spec(cards)

    assert state_spec["facet"]["row"]["field"] == "issue_key"
    assert state_spec["spec"]["mark"]["shape"] == "diamond"
    assert state_spec["spec"]["encoding"]["color"]["value"] == "#3b82f6"

    assert comment_spec["spec"]["mark"]["shape"] == "circle"
    assert comment_spec["spec"]["encoding"]["color"]["value"] == "#f59e0b"

    assert tag_spec["spec"]["mark"]["shape"] == "square"

    assert tag_spec["spec"]["encoding"]["color"]["scale"] == %{
             "domain" => ["added", "removed", "mixed"],
             "range" => ["#10b981", "#ef4444", "#8b5cf6"]
           }

    tag_change_types = tag_spec["data"]["values"] |> Enum.map(& &1["change_type"]) |> Enum.sort()
    assert tag_change_types == ["added", "removed"]
  end
end
