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
    assert Enum.any?(result.time_in_state, &(&1.state == "In Progress" and &1.duration_ms == 7_000))
    assert hd(result.active_segments).label in ["Active", "Inactive"]
    assert hd(result.timeline_events).timestamp == 9_000
  end
end