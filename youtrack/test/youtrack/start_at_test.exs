defmodule Youtrack.StartAtTest do
  use ExUnit.Case, async: true

  alias Youtrack.StartAt

  describe "from_activities/3" do
    test "finds earliest in-progress transition" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "timestamp" => 1_700_200_000_000
        },
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "timestamp" => 1_700_100_000_000
        }
      ]

      assert 1_700_100_000_000 == StartAt.from_activities(activities, "State", ["In Progress"])
    end

    test "returns nil when no matching transitions" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "Done"}],
          "timestamp" => 1_700_000_000_000
        }
      ]

      assert nil == StartAt.from_activities(activities, "State", ["In Progress"])
    end

    test "returns nil for empty activities" do
      assert nil == StartAt.from_activities([], "State", ["In Progress"])
    end

    test "ignores activities for other fields" do
      activities = [
        %{
          "field" => %{"name" => "Priority"},
          "added" => [%{"name" => "In Progress"}],
          "timestamp" => 1_700_000_000_000
        }
      ]

      assert nil == StartAt.from_activities(activities, "State", ["In Progress"])
    end

    test "handles multiple in-progress state names" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "Working"}],
          "timestamp" => 1_700_000_000_000
        }
      ]

      assert 1_700_000_000_000 ==
               StartAt.from_activities(activities, "State", ["In Progress", "Working"])
    end

    test "handles nil added field" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => nil,
          "timestamp" => 1_700_000_000_000
        }
      ]

      assert nil == StartAt.from_activities(activities, "State", ["In Progress"])
    end

    test "filters out non-integer timestamps" do
      activities = [
        %{
          "field" => %{"name" => "State"},
          "added" => [%{"name" => "In Progress"}],
          "timestamp" => nil
        }
      ]

      assert nil == StartAt.from_activities(activities, "State", ["In Progress"])
    end
  end
end
