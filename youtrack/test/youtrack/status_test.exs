defmodule Youtrack.StatusTest do
  use ExUnit.Case, async: true

  alias Youtrack.Status

  describe "classify/3" do
    test "returns finished when resolved is set" do
      issue = %{"resolved" => 1_700_000_000_000}
      assert "finished" == Status.classify(issue, "In Progress", ["In Progress"])
    end

    test "returns finished even if state is in progress" do
      issue = %{"resolved" => 1_700_000_000_000}
      assert "finished" == Status.classify(issue, "In Progress", ["In Progress"])
    end

    test "returns ongoing when state is in progress and not resolved" do
      issue = %{"resolved" => nil}
      assert "ongoing" == Status.classify(issue, "In Progress", ["In Progress"])
    end

    test "returns ongoing with multiple in-progress state names" do
      issue = %{"resolved" => nil}
      assert "ongoing" == Status.classify(issue, "Working", ["In Progress", "Working"])
    end

    test "returns unfinished when not resolved and not in progress" do
      issue = %{"resolved" => nil}
      assert "unfinished" == Status.classify(issue, "Open", ["In Progress"])
    end

    test "returns unfinished when resolved is missing" do
      issue = %{}
      assert "unfinished" == Status.classify(issue, "Open", ["In Progress"])
    end

    test "returns unfinished when state_name is nil" do
      issue = %{"resolved" => nil}
      assert "unfinished" == Status.classify(issue, nil, ["In Progress"])
    end
  end
end
