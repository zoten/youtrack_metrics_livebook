defmodule Youtrack.WeeklyReportTest do
  use ExUnit.Case, async: true

  alias Youtrack.WeeklyReport

  # ---------------------------------------------------------------------------
  # extract_checklist/1
  # ---------------------------------------------------------------------------

  describe "extract_checklist/1" do
    test "returns zeroes for nil description" do
      assert WeeklyReport.extract_checklist(nil) == %{checked: 0, unchecked: 0, items: []}
    end

    test "returns zeroes for empty description" do
      assert WeeklyReport.extract_checklist("") == %{checked: 0, unchecked: 0, items: []}
    end

    test "returns zeroes when no checkboxes" do
      assert WeeklyReport.extract_checklist("Some plain text\nAnother line") ==
               %{checked: 0, unchecked: 0, items: []}
    end

    test "extracts a checked item" do
      result = WeeklyReport.extract_checklist("- [x] Done task")
      assert result.checked == 1
      assert result.unchecked == 0
      assert result.items == [{:checked, "Done task"}]
    end

    test "extracts a checked item with uppercase X" do
      result = WeeklyReport.extract_checklist("- [X] Done task")
      assert result.checked == 1
      assert result.unchecked == 0
    end

    test "extracts an unchecked item" do
      result = WeeklyReport.extract_checklist("- [ ] Pending task")
      assert result.checked == 0
      assert result.unchecked == 1
      assert result.items == [{:unchecked, "Pending task"}]
    end

    test "extracts mixed items" do
      description = """
      Some context

      - [x] First done
      - [ ] Still pending
      - [X] Also done
      - [ ] Another pending
      """

      result = WeeklyReport.extract_checklist(description)
      assert result.checked == 2
      assert result.unchecked == 2
      assert length(result.items) == 4
    end

    test "ignores lines that look almost like checkboxes" do
      result = WeeklyReport.extract_checklist("- [X done\n- [ done")
      assert result.checked == 0
      assert result.unchecked == 0
    end
  end

  # ---------------------------------------------------------------------------
  # format_duration/1
  # ---------------------------------------------------------------------------

  describe "format_duration/1" do
    test "returns N/A for nil" do
      assert WeeklyReport.format_duration(nil) == "N/A"
    end

    test "returns < 1h for zero ms" do
      assert WeeklyReport.format_duration(0) == "< 1h"
    end

    test "returns < 1h for negative ms" do
      assert WeeklyReport.format_duration(-1000) == "< 1h"
    end

    test "returns < 1h for less than one hour" do
      assert WeeklyReport.format_duration(1_800_000) == "< 1h"
    end

    test "returns hours for less than a day" do
      assert WeeklyReport.format_duration(3 * 3_600_000) == "3h"
    end

    test "returns days and hours" do
      ms = 25 * 3_600_000
      assert WeeklyReport.format_duration(ms) == "1d 1h"
    end

    test "returns days only when no remainder hours" do
      ms = 48 * 3_600_000
      assert WeeklyReport.format_duration(ms) == "2d"
    end
  end

  # ---------------------------------------------------------------------------
  # net_active_time/4
  # ---------------------------------------------------------------------------

  describe "net_active_time/4" do
    @start_ms 1_000_000
    @end_ms 5_000_000

    test "returns nil when start_ms is nil" do
      assert WeeklyReport.net_active_time(nil, @end_ms, [], ["on hold"]) == nil
    end

    test "returns nil when end_ms is nil" do
      assert WeeklyReport.net_active_time(@start_ms, nil, [], ["on hold"]) == nil
    end

    test "returns full duration when no hold activities" do
      assert WeeklyReport.net_active_time(@start_ms, @end_ms, [], ["on hold"]) ==
               @end_ms - @start_ms
    end

    test "subtracts hold period fully within window" do
      activities = [
        %{
          "field" => %{"name" => "tags"},
          "added" => [%{"name" => "on hold"}],
          "removed" => [],
          "timestamp" => 2_000_000
        },
        %{
          "field" => %{"name" => "tags"},
          "added" => [],
          "removed" => [%{"name" => "on hold"}],
          "timestamp" => 3_000_000
        }
      ]

      # Hold period: 2_000_000 to 3_000_000 = 1_000_000 ms
      result = WeeklyReport.net_active_time(@start_ms, @end_ms, activities, ["on hold"])
      assert result == @end_ms - @start_ms - 1_000_000
    end

    test "handles hold that starts before window (issue already on hold at start)" do
      # Issue was put on hold before start_ms
      activities = [
        %{
          "field" => %{"name" => "tags"},
          "added" => [%{"name" => "on hold"}],
          "removed" => [],
          "timestamp" => 500_000
        },
        %{
          "field" => %{"name" => "tags"},
          "added" => [],
          "removed" => [%{"name" => "on hold"}],
          "timestamp" => 2_000_000
        }
      ]

      # Hold covers start_ms (1_000_000) to 2_000_000 = 1_000_000 ms paused
      result = WeeklyReport.net_active_time(@start_ms, @end_ms, activities, ["on hold"])
      assert result == @end_ms - @start_ms - 1_000_000
    end

    test "handles hold that extends beyond end of window" do
      activities = [
        %{
          "field" => %{"name" => "tags"},
          "added" => [%{"name" => "on hold"}],
          "removed" => [],
          "timestamp" => 4_000_000
        }
        # Never removed — still on hold at end_ms
      ]

      # Hold covers 4_000_000 to end_ms = 1_000_000 ms paused
      result = WeeklyReport.net_active_time(@start_ms, @end_ms, activities, ["on hold"])
      assert result == @end_ms - @start_ms - 1_000_000
    end

    test "handles multiple hold tags (on hold + blocked)" do
      activities = [
        %{
          "field" => %{"name" => "tags"},
          "added" => [%{"name" => "blocked"}],
          "removed" => [],
          "timestamp" => 2_000_000
        },
        %{
          "field" => %{"name" => "tags"},
          "added" => [],
          "removed" => [%{"name" => "blocked"}],
          "timestamp" => 3_000_000
        }
      ]

      result =
        WeeklyReport.net_active_time(@start_ms, @end_ms, activities, ["on hold", "blocked"])

      assert result == @end_ms - @start_ms - 1_000_000
    end

    test "is case-insensitive for hold tag matching" do
      activities = [
        %{
          "field" => %{"name" => "tags"},
          "added" => [%{"name" => "On Hold"}],
          "removed" => [],
          "timestamp" => 2_000_000
        },
        %{
          "field" => %{"name" => "tags"},
          "added" => [],
          "removed" => [%{"name" => "On Hold"}],
          "timestamp" => 3_000_000
        }
      ]

      result = WeeklyReport.net_active_time(@start_ms, @end_ms, activities, ["on hold"])
      assert result == @end_ms - @start_ms - 1_000_000
    end

    test "ignores activities for non-tag fields" do
      state_activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "removed" => [],
          "timestamp" => 2_000_000
        }
      ]

      result =
        WeeklyReport.net_active_time(@start_ms, @end_ms, state_activities, ["on hold"])

      assert result == @end_ms - @start_ms
    end

    test "returns zero when entire window is on hold" do
      activities = [
        %{
          "field" => %{"name" => "tags"},
          "added" => [%{"name" => "on hold"}],
          "removed" => [],
          "timestamp" => 0
        }
        # Never removed
      ]

      result = WeeklyReport.net_active_time(@start_ms, @end_ms, activities, ["on hold"])
      assert result == 0
    end
  end

  # ---------------------------------------------------------------------------
  # build_issue_summary/3
  # ---------------------------------------------------------------------------

  describe "build_issue_summary/3" do
    defp make_issue(overrides \\ %{}) do
      Map.merge(
        %{
          "idReadable" => "PROJ-1",
          "id" => "3-1",
          "summary" => "Test issue",
          "description" => nil,
          "created" => 1_000_000,
          "updated" => 4_000_000,
          "resolved" => nil,
          "project" => %{"shortName" => "PROJ"},
          "tags" => [],
          "customFields" => [
            %{"name" => "State", "value" => %{"name" => "In Progress"}},
            %{"name" => "Assignee", "value" => %{"login" => "alice", "name" => "Alice"}}
          ],
          "comments" => []
        },
        overrides
      )
    end

    test "returns basic metadata fields" do
      issue = make_issue()
      summary = WeeklyReport.build_issue_summary(issue, [])

      assert summary.id == "PROJ-1"
      assert summary.title == "Test issue"
      assert summary.state == "In Progress"
      assert summary.assignees == ["Alice"]
    end

    test "extracts special tags present on the issue" do
      issue = make_issue(%{"tags" => [%{"name" => "on hold"}, %{"name" => "team:backend"}]})
      summary = WeeklyReport.build_issue_summary(issue, [])

      assert "on hold" in summary.special_tags
      refute "team:backend" in summary.special_tags
    end

    test "sets is_on_hold true when hold tag present" do
      issue = make_issue(%{"tags" => [%{"name" => "on hold"}]})
      summary = WeeklyReport.build_issue_summary(issue, [], hold_tags: ["on hold"])

      assert summary.is_on_hold == true
    end

    test "sets is_on_hold false when no hold tag present" do
      issue = make_issue(%{"tags" => [%{"name" => "team:backend"}]})
      summary = WeeklyReport.build_issue_summary(issue, [])

      assert summary.is_on_hold == false
    end

    test "filters state changes to window" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "removed" => [%{"name" => "Open"}],
          "timestamp" => 500_000
        },
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "Done"}],
          "removed" => [%{"name" => "In Progress"}],
          "timestamp" => 3_000_000
        }
      ]

      summary =
        WeeklyReport.build_issue_summary(
          make_issue(%{"resolved" => 3_000_000}),
          activities,
          window_start_ms: 2_000_000,
          window_end_ms: 4_000_000
        )

      assert length(summary.state_changes_in_window) == 1
      assert hd(summary.state_changes_in_window).to == ["Done"]
    end

    test "filters comments to window" do
      issue =
        make_issue(%{
          "comments" => [
            %{
              "id" => "c1",
              "text" => "Old comment",
              "created" => 500_000,
              "author" => %{"login" => "alice", "name" => "Alice"}
            },
            %{
              "id" => "c2",
              "text" => "New comment",
              "created" => 3_000_000,
              "author" => %{"login" => "bob", "name" => "Bob"}
            }
          ]
        })

      summary =
        WeeklyReport.build_issue_summary(
          issue,
          [],
          window_start_ms: 2_000_000,
          window_end_ms: 4_000_000
        )

      assert length(summary.comments_in_window) == 1
      assert hd(summary.comments_in_window).text == "New comment"
    end

    test "extracts checklist from description" do
      issue = make_issue(%{"description" => "- [x] Done\n- [ ] Pending"})
      summary = WeeklyReport.build_issue_summary(issue, [])

      assert summary.checklist.checked == 1
      assert summary.checklist.unchecked == 1
    end

    test "falls back to created when no inactive-to-active transition is found" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "removed" => [%{"name" => "Open"}],
          "timestamp" => 1_000_000
        }
      ]

      issue = make_issue(%{"resolved" => 5_000_000, "created" => 0})
      summary = WeeklyReport.build_issue_summary(issue, activities)

      assert summary.cycle_time_ms == 5_000_000
    end

    test "cycle time starts at inactive to active transition" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "To Do"}],
          "removed" => [],
          "timestamp" => 1_000_000
        },
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "Review"}],
          "removed" => [%{"name" => "To Do"}],
          "timestamp" => 2_000_000
        }
      ]

      issue = make_issue(%{"resolved" => 5_000_000, "created" => 500_000})
      summary = WeeklyReport.build_issue_summary(issue, activities)

      assert summary.cycle_time_ms == 5_000_000 - 2_000_000
    end

    test "cycle time starts when state appears from no-state" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "removed" => [],
          "timestamp" => 3_000_000
        }
      ]

      issue = make_issue(%{"resolved" => 8_000_000, "created" => 1_000_000})
      summary = WeeklyReport.build_issue_summary(issue, activities)

      assert summary.cycle_time_ms == 8_000_000 - 3_000_000
    end

    test "flags description_updated_in_window when updated falls in window" do
      summary =
        WeeklyReport.build_issue_summary(
          make_issue(%{"updated" => 3_000_000}),
          [],
          window_start_ms: 2_000_000,
          window_end_ms: 4_000_000
        )

      assert summary.description_updated_in_window == true
    end

    test "passes through workstreams from opts" do
      summary =
        WeeklyReport.build_issue_summary(make_issue(), [], workstreams: ["BACKEND", "API"])

      assert summary.workstreams == ["BACKEND", "API"]
    end
  end
end
