defmodule Youtrack.RotationTest do
  use ExUnit.Case, async: true

  alias Youtrack.Rotation

  # Helper to build work items with minimal fields
  defp wi(person, stream, start_at_unix, issue_id \\ nil) do
    %{
      person_login: person,
      person_name: person,
      stream: stream,
      start_at: start_at_unix * 1000,
      issue_id: issue_id || "PROJ-#{:rand.uniform(10000)}",
      created: start_at_unix * 1000
    }
  end

  # Monday timestamps for sequential weeks (2024-01-01 is a Monday)
  # 2024-01-01
  @week1 1_704_067_200
  # 2024-01-08
  @week2 1_704_672_000
  # 2024-01-15
  @week3 1_705_276_800
  # 2024-01-22
  @week4 1_705_881_600
  # 2024-01-29
  @week5 1_706_486_400

  describe "timeline_by_person/1" do
    test "builds weekly timeline for a single person" do
      items = [
        wi("alice", "Backend", @week1),
        wi("alice", "Backend", @week1),
        wi("alice", "Frontend", @week2)
      ]

      result = Rotation.timeline_by_person(items)
      assert Map.has_key?(result, "alice")

      timeline = result["alice"]
      assert length(timeline) == 2
      assert hd(timeline).primary_stream == "Backend"
      assert List.last(timeline).primary_stream == "Frontend"
    end

    test "picks primary stream by frequency" do
      items = [
        wi("alice", "Backend", @week1, "P-1"),
        wi("alice", "Backend", @week1, "P-2"),
        wi("alice", "Frontend", @week1, "P-3")
      ]

      result = Rotation.timeline_by_person(items)
      timeline = result["alice"]
      assert hd(timeline).primary_stream == "Backend"
    end

    test "filters out items without start_at" do
      items = [
        %{person_login: "alice", stream: "Backend", start_at: nil, issue_id: "P-1", created: nil}
      ]

      result = Rotation.timeline_by_person(items)
      assert result == %{}
    end
  end

  describe "metrics_by_person/1" do
    test "computes metrics for single stream person" do
      items = [
        wi("alice", "Backend", @week1),
        wi("alice", "Backend", @week2),
        wi("alice", "Backend", @week3)
      ]

      [metric] = Rotation.metrics_by_person(items)
      assert metric.person == "alice"
      assert metric.unique_streams == 1
      assert metric.switches == 0
      assert metric.boomerang_rate == 0.0
      assert metric.avg_tenure_weeks == 3.0
      assert metric.journey == "Backend"
    end

    test "detects switches between streams" do
      items = [
        wi("alice", "Backend", @week1),
        wi("alice", "Frontend", @week2),
        wi("alice", "Backend", @week3)
      ]

      [metric] = Rotation.metrics_by_person(items)
      assert metric.switches == 2
      assert metric.unique_streams == 2
      assert metric.journey == "Backend → Frontend → Backend"
    end

    test "computes boomerang rate" do
      items = [
        wi("alice", "A", @week1),
        wi("alice", "B", @week2),
        wi("alice", "A", @week3),
        wi("alice", "C", @week4)
      ]

      [metric] = Rotation.metrics_by_person(items)
      # Switches: A→B, B→A (boomerang), A→C = 3 switches, 1 boomerang
      assert metric.switches == 3
      assert metric.boomerang_rate == Float.round(1 / 3 * 100, 1)
    end

    test "computes average tenure" do
      items = [
        wi("alice", "A", @week1),
        wi("alice", "A", @week2),
        wi("alice", "B", @week3),
        wi("alice", "C", @week4),
        wi("alice", "C", @week5)
      ]

      [metric] = Rotation.metrics_by_person(items)
      # Runs: A(2), B(1), C(2) → avg = 5/3 ≈ 1.7
      assert metric.avg_tenure_weeks == Float.round(5 / 3, 1)
    end

    test "handles multiple people" do
      items = [
        wi("alice", "A", @week1),
        wi("alice", "B", @week2),
        wi("bob", "A", @week1),
        wi("bob", "A", @week2)
      ]

      metrics = Rotation.metrics_by_person(items)
      assert length(metrics) == 2

      alice = Enum.find(metrics, &(&1.person == "alice"))
      bob = Enum.find(metrics, &(&1.person == "bob"))
      assert alice.switches == 1
      assert bob.switches == 0
    end
  end

  describe "person_week_stream/1" do
    test "produces flat list for heatmap" do
      items = [
        wi("alice", "Backend", @week1, "P-1"),
        wi("alice", "Backend", @week1, "P-2"),
        wi("alice", "Frontend", @week1, "P-3"),
        wi("alice", "Frontend", @week2, "P-4")
      ]

      result = Rotation.person_week_stream(items)

      assert length(result) == 3
      assert Enum.all?(result, &Map.has_key?(&1, :person))
      assert Enum.all?(result, &Map.has_key?(&1, :week))
      assert Enum.all?(result, &Map.has_key?(&1, :stream))
      assert Enum.all?(result, &Map.has_key?(&1, :item_count))
    end
  end

  describe "stream_tenure/1" do
    test "computes tenure per person per stream" do
      items = [
        wi("alice", "A", @week1),
        wi("alice", "A", @week2),
        wi("alice", "B", @week3),
        wi("alice", "A", @week4),
        wi("alice", "A", @week5)
      ]

      result = Rotation.stream_tenure(items)

      a_tenure = Enum.find(result, &(&1.person == "alice" and &1.stream == "A"))
      b_tenure = Enum.find(result, &(&1.person == "alice" and &1.stream == "B"))

      assert a_tenure.total_weeks == 4
      assert a_tenure.stints == 2
      assert a_tenure.avg_stint_weeks == 2.0

      assert b_tenure.total_weeks == 1
      assert b_tenure.stints == 1
    end
  end
end
