defmodule Youtrack.ReworkTest do
  use ExUnit.Case, async: true

  alias Youtrack.Rework

  describe "detect/3" do
    test "returns empty list when no activities" do
      assert Rework.detect([], "State", ["Done"]) == []
    end

    test "returns empty list when no rework events" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "removed" => [%{"name" => "Open"}],
          "timestamp" => 1000
        },
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "Done"}],
          "removed" => [%{"name" => "In Progress"}],
          "timestamp" => 2000
        }
      ]

      assert Rework.detect(activities, "State", ["Done"]) == []
    end

    test "detects a single rework event" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "Done"}],
          "removed" => [%{"name" => "In Progress"}],
          "timestamp" => 1000
        },
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "removed" => [%{"name" => "Done"}],
          "timestamp" => 2000
        }
      ]

      result = Rework.detect(activities, "State", ["Done"])
      assert length(result) == 1
      assert hd(result).timestamp == 2000
      assert hd(result).from == ["Done"]
      assert hd(result).to == ["In Progress"]
    end

    test "detects multiple rework events" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "Done"}],
          "removed" => [%{"name" => "In Progress"}],
          "timestamp" => 1000
        },
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "removed" => [%{"name" => "Done"}],
          "timestamp" => 2000
        },
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "Done"}],
          "removed" => [%{"name" => "In Progress"}],
          "timestamp" => 3000
        },
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "Open"}],
          "removed" => [%{"name" => "Done"}],
          "timestamp" => 4000
        }
      ]

      result = Rework.detect(activities, "State", ["Done"])
      assert length(result) == 2
      assert Enum.map(result, & &1.timestamp) == [2000, 4000]
    end

    test "ignores activities for other fields" do
      activities = [
        %{
          "field" => %{"name" => "Priority"},
          "added" => [%{"name" => "High"}],
          "removed" => [%{"name" => "Done"}],
          "timestamp" => 1000
        }
      ]

      assert Rework.detect(activities, "State", ["Done"]) == []
    end

    test "handles multiple done state names" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "removed" => [%{"name" => "Verified"}],
          "timestamp" => 1000
        }
      ]

      result = Rework.detect(activities, "State", ["Done", "Verified", "Fixed"])
      assert length(result) == 1
      assert hd(result).from == ["Verified"]
    end

    test "handles nil/missing removed field" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "timestamp" => 1000
        }
      ]

      assert Rework.detect(activities, "State", ["Done"]) == []
    end
  end

  describe "count_by_issue/3" do
    test "returns empty map when no rework" do
      activities_map = %{
        "issue-1" => [
          %{
            "field" => %{"name" => "State"},
            "added" => [%{"name" => "Done"}],
            "removed" => [%{"name" => "Open"}],
            "timestamp" => 1000
          }
        ]
      }

      assert Rework.count_by_issue(activities_map, "State", ["Done"]) == %{}
    end

    test "counts rework events per issue" do
      activities_map = %{
        "issue-1" => [
          %{
            "field" => %{"name" => "State"},
            "added" => [%{"name" => "Done"}],
            "removed" => [%{"name" => "In Progress"}],
            "timestamp" => 1000
          },
          %{
            "field" => %{"name" => "State"},
            "added" => [%{"name" => "In Progress"}],
            "removed" => [%{"name" => "Done"}],
            "timestamp" => 2000
          }
        ],
        "issue-2" => [
          %{
            "field" => %{"name" => "State"},
            "added" => [%{"name" => "Done"}],
            "removed" => [%{"name" => "Open"}],
            "timestamp" => 1000
          }
        ],
        "issue-3" => [
          %{
            "field" => %{"name" => "State"},
            "added" => [%{"name" => "Done"}],
            "removed" => [%{"name" => "In Progress"}],
            "timestamp" => 1000
          },
          %{
            "field" => %{"name" => "State"},
            "added" => [%{"name" => "Open"}],
            "removed" => [%{"name" => "Done"}],
            "timestamp" => 2000
          },
          %{
            "field" => %{"name" => "State"},
            "added" => [%{"name" => "Done"}],
            "removed" => [%{"name" => "In Progress"}],
            "timestamp" => 3000
          },
          %{
            "field" => %{"name" => "State"},
            "added" => [%{"name" => "Open"}],
            "removed" => [%{"name" => "Done"}],
            "timestamp" => 4000
          }
        ]
      }

      result = Rework.count_by_issue(activities_map, "State", ["Done"])
      assert result == %{"issue-1" => 1, "issue-3" => 2}
    end
  end
end
