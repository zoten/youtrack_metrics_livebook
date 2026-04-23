defmodule Youtrack.CardFocusTest do
  use ExUnit.Case, async: true

  alias Youtrack.CardFocus

  test "builds card insights from issue history" do
    issue = %{
      "idReadable" => "PROJ-7",
      "id" => "3-7",
      "summary" => "[BACKEND] Improve retry flow",
      "description" => "old description",
      "created" => 1_000,
      "updated" => 9_000,
      "resolved" => 9_000,
      "project" => %{"shortName" => "PROJ"},
      "type" => %{"name" => "Task"},
      "tags" => [%{"name" => "team:backend"}, %{"name" => "blocked"}],
      "comments" => [
        %{
          "id" => "c1",
          "text" => "Looks good now",
          "created" => 8_500,
          "author" => %{"name" => "Bob", "login" => "bob"}
        }
      ],
      "customFields" => [
        %{"name" => "State", "value" => %{"name" => "Done"}},
        %{"name" => "Assignee", "value" => %{"name" => "Bob", "login" => "bob"}}
      ]
    }

    activities = [
      %{
        "field" => %{"name" => "State"},
        "added" => [%{"name" => "In Progress"}],
        "removed" => [%{"name" => "To Do"}],
        "timestamp" => 2_000,
        "author" => %{"name" => "Alice"}
      },
      %{
        "field" => %{"name" => "Assignee"},
        "added" => [%{"name" => "Bob"}],
        "removed" => [%{"name" => "Alice"}],
        "timestamp" => 4_000,
        "author" => %{"name" => "Lead"}
      },
      %{
        "field" => %{"name" => "tags"},
        "added" => [%{"name" => "blocked"}],
        "removed" => [],
        "timestamp" => 5_000,
        "author" => %{"name" => "Bob"}
      },
      %{
        "field" => %{"name" => "tags"},
        "added" => [],
        "removed" => [%{"name" => "blocked"}],
        "timestamp" => 6_000,
        "author" => %{"name" => "Bob"}
      },
      %{
        "category" => %{"id" => "DescriptionCategory"},
        "field" => %{"name" => "description"},
        "added" => [%{"text" => "new description"}],
        "removed" => [%{"text" => "old description"}],
        "timestamp" => 7_000,
        "author" => %{"name" => "Bob"}
      },
      %{
        "field" => %{"name" => "State"},
        "added" => [%{"name" => "Done"}],
        "removed" => [%{"name" => "In Progress"}],
        "timestamp" => 9_000,
        "author" => %{"name" => "Bob"}
      }
    ]

    result =
      CardFocus.build(
        issue,
        activities,
        state_field: "State",
        assignees_field: "Assignee",
        inactive_names: ["To Do"],
        done_names: ["Done"],
        hold_tags: ["blocked"],
        workstreams: ["BACKEND"]
      )

    assert result.issue.issue_key == "PROJ-7"
    assert result.issue.workstreams == ["BACKEND"]
    assert result.metrics.cycle_time_ms == 7_000
    assert result.metrics.net_active_time_ms == 6_000
    assert result.metrics.inactive_time_ms == 1_000
    assert result.metrics.active_ratio_pct == 85.7
    assert length(result.assignee_events) == 1
    assert length(result.tag_events) == 2
    assert length(result.description_events) == 1
    assert length(result.comment_events) == 1
    assert length(result.rework_events) == 0

    assert Enum.any?(
             result.time_in_state,
             &(&1.state == "In Progress" and &1.duration_ms == 7_000)
           )

    assert hd(result.active_segments).label in ["Active", "Inactive"]
    assert hd(result.timeline_events).timestamp == 9_000
  end

  test "detects hold and tag events when activities use category.id without field.name" do
    # Regression: YouTrack TagsCategory activities may omit the field map entirely
    issue = %{
      "idReadable" => "T-2",
      "id" => "3-2",
      "summary" => "Issue with category-only tag activities",
      "description" => nil,
      "created" => 1_000,
      "updated" => 9_000,
      "resolved" => 9_000,
      "project" => %{"shortName" => "T"},
      "type" => %{"name" => "Task"},
      "tags" => [],
      "comments" => [],
      "customFields" => [
        %{"name" => "State", "value" => %{"name" => "In Progress"}}
      ]
    }

    activities = [
      %{
        "field" => %{"name" => "State"},
        "added" => [%{"name" => "In Progress"}],
        "removed" => [%{"name" => "To Do"}],
        "timestamp" => 2_000,
        "author" => %{"name" => "Alice"}
      },
      # Tag activity with category.id but no field key (simulates null-field YouTrack response)
      %{
        "category" => %{"id" => "TagsCategory"},
        "added" => [%{"name" => "on hold"}],
        "removed" => [],
        "timestamp" => 4_000,
        "author" => %{"name" => "Alice"}
      },
      %{
        "category" => %{"id" => "TagsCategory"},
        "added" => [],
        "removed" => [%{"name" => "on hold"}],
        "timestamp" => 6_000,
        "author" => %{"name" => "Alice"}
      }
    ]

    result =
      CardFocus.build(
        issue,
        activities,
        state_field: "State",
        assignees_field: "Assignee",
        inactive_names: ["To Do"],
        done_names: ["Done"],
        hold_tags: ["on hold"]
      )

    # Cycle: 2_000 to 9_000 = 7_000; hold 4_000–6_000 = 2_000 paused
    assert result.metrics.cycle_time_ms == 7_000
    assert result.metrics.net_active_time_ms == 5_000
    assert result.metrics.inactive_time_ms == 2_000
    # Two tag events should be surfaced (add and remove)
    assert length(result.tag_events) == 2

    # Active segments should have hold carved out:
    #   Active 2_000–4_000, On Hold 4_000–6_000, Active 6_000–9_000
    active_labels = Enum.map(result.active_segments, & &1.label)
    assert active_labels == ["Active", "On Hold", "Active"]

    [seg1, hold_seg, seg2] = result.active_segments
    assert seg1.start_ms == 2_000
    assert seg1.end_ms == 4_000
    assert hold_seg.start_ms == 4_000
    assert hold_seg.end_ms == 6_000
    assert seg2.start_ms == 6_000
    assert seg2.end_ms == 9_000
  end

  test "splits state segments when sprint assignment changes" do
    issue = %{
      "idReadable" => "T-3",
      "id" => "3-3",
      "summary" => "Sprint-aware segmentation",
      "description" => nil,
      "created" => 1_000,
      "updated" => 10_000,
      "resolved" => 10_000,
      "project" => %{"shortName" => "T"},
      "type" => %{"name" => "Task"},
      "tags" => [],
      "comments" => [],
      "customFields" => [
        %{"name" => "State", "value" => %{"name" => "Done"}},
        %{"name" => "Sprint", "value" => nil}
      ]
    }

    activities = [
      %{
        "field" => %{"name" => "State"},
        "added" => [%{"name" => "In Progress"}],
        "removed" => [%{"name" => "To Do"}],
        "timestamp" => 2_000,
        "author" => %{"name" => "Alice"}
      },
      %{
        "field" => %{"name" => "Sprint"},
        "added" => [%{"name" => "Sprint 15"}],
        "removed" => [],
        "timestamp" => 4_000,
        "author" => %{"name" => "Planner"}
      },
      %{
        "field" => %{"name" => "State"},
        "added" => [%{"name" => "Done"}],
        "removed" => [%{"name" => "In Progress"}],
        "timestamp" => 8_000,
        "author" => %{"name" => "Alice"}
      }
    ]

    result =
      CardFocus.build(
        issue,
        activities,
        state_field: "State",
        assignees_field: "Assignee",
        inactive_names: ["To Do"],
        done_names: ["Done"],
        sprint_field: "Sprint"
      )

    assert Enum.map(result.state_segments, &{&1.state, &1.start_ms, &1.end_ms, &1.has_sprint?}) ==
             [
               {"To Do", 1_000, 2_000, false},
               {"In Progress", 2_000, 4_000, false},
               {"In Progress", 4_000, 8_000, true},
               {"Done", 8_000, 10_000, true}
             ]
  end
end
