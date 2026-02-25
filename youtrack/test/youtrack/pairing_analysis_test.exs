defmodule Youtrack.PairingAnalysisTest do
  use ExUnit.Case, async: true

  alias Youtrack.PairingAnalysis

  @rules %{
    slug_prefix_to_stream: %{"BACKEND" => ["BACKEND"]},
    tag_to_stream: %{},
    substream_of: %{},
    fallback: ["(unclassified)"]
  }

  defp make_issue(id, assignee_logins, overrides \\ %{}) do
    assignee_value =
      case assignee_logins do
        [single] -> %{"login" => single, "name" => single}
        multiple -> Enum.map(multiple, fn l -> %{"login" => l, "name" => l} end)
      end

    Map.merge(
      %{
        "id" => id,
        "idReadable" => "PROJ-#{id}",
        "summary" => "[BACKEND] Task #{id}",
        "created" => 1_700_000_000_000,
        "resolved" => nil,
        "project" => %{"shortName" => "PROJ"},
        "customFields" => [
          %{"name" => "Assignee", "value" => assignee_value}
        ],
        "tags" => []
      },
      overrides
    )
  end

  @default_opts [
    assignees_field: "Assignee",
    workstream_rules: @rules,
    include_substreams: true
  ]

  describe "extract_pairs/2" do
    test "extracts pairs from issues with 2+ assignees" do
      issues = [make_issue("1", ["alice", "bob"])]
      pairs = PairingAnalysis.extract_pairs(issues, @default_opts)

      assert length(pairs) == 1
      pair = hd(pairs)
      assert pair.person_a == "alice"
      assert pair.person_b == "bob"
    end

    test "generates all combinations for 3 assignees" do
      issues = [make_issue("1", ["alice", "bob", "charlie"])]
      pairs = PairingAnalysis.extract_pairs(issues, @default_opts)

      pair_tuples = Enum.map(pairs, &{&1.person_a, &1.person_b}) |> Enum.sort()
      assert {"alice", "bob"} in pair_tuples
      assert {"alice", "charlie"} in pair_tuples
      assert {"bob", "charlie"} in pair_tuples
    end

    test "skips issues with only one assignee" do
      issues = [make_issue("1", ["alice"])]
      pairs = PairingAnalysis.extract_pairs(issues, @default_opts)
      assert pairs == []
    end

    test "excludes specified logins" do
      issues = [make_issue("1", ["alice", "bob", "bot"])]
      opts = Keyword.put(@default_opts, :excluded_logins, ["bot"])
      pairs = PairingAnalysis.extract_pairs(issues, opts)

      assert length(pairs) == 1
      assert hd(pairs).person_a == "alice"
      assert hd(pairs).person_b == "bob"
    end

    test "tags unplanned pairs" do
      issues = [
        make_issue("1", ["alice", "bob"], %{
          "tags" => [%{"name" => "on the ankles"}]
        })
      ]

      opts = Keyword.put(@default_opts, :unplanned_tag, "on the ankles")
      pairs = PairingAnalysis.extract_pairs(issues, opts)
      assert hd(pairs).is_unplanned
    end

    test "includes workstream in pair records" do
      issues = [make_issue("1", ["alice", "bob"])]
      pairs = PairingAnalysis.extract_pairs(issues, @default_opts)
      assert hd(pairs).workstream == "BACKEND"
    end

    test "includes created_date" do
      issues = [make_issue("1", ["alice", "bob"])]
      pairs = PairingAnalysis.extract_pairs(issues, @default_opts)
      assert %Date{} = hd(pairs).created_date
    end
  end

  describe "pair_matrix/1" do
    test "builds symmetric matrix" do
      records = [
        %{person_a: "alice", person_b: "bob"},
        %{person_a: "alice", person_b: "bob"}
      ]

      matrix = PairingAnalysis.pair_matrix(records)
      ab = Enum.find(matrix, &(&1.person_a == "alice" and &1.person_b == "bob"))
      ba = Enum.find(matrix, &(&1.person_a == "bob" and &1.person_b == "alice"))
      assert ab.count == 2
      assert ba.count == 2
    end
  end

  describe "trend_by_week/1" do
    test "groups by week" do
      records = [
        %{person_a: "a", person_b: "b", created_date: ~D[2024-01-08]},
        %{person_a: "a", person_b: "b", created_date: ~D[2024-01-09]},
        %{person_a: "a", person_b: "c", created_date: ~D[2024-01-15]}
      ]

      trend = PairingAnalysis.trend_by_week(records)
      assert length(trend) == 2

      week1 = Enum.find(trend, &(&1.week == "2024-01-08"))
      assert week1.pair_count == 2
      assert week1.unique_pairs == 1
    end

    test "skips records with nil created_date" do
      records = [
        %{person_a: "a", person_b: "b", created_date: nil}
      ]

      assert [] == PairingAnalysis.trend_by_week(records)
    end
  end

  describe "by_workstream/1" do
    test "groups by workstream" do
      records = [
        %{person_a: "a", person_b: "b", workstream: "BACKEND"},
        %{person_a: "a", person_b: "b", workstream: "BACKEND"},
        %{person_a: "a", person_b: "c", workstream: "FRONTEND"}
      ]

      by_ws = PairingAnalysis.by_workstream(records)
      backend = Enum.find(by_ws, &(&1.workstream == "BACKEND"))
      assert backend.pair_count == 2
      assert backend.unique_pairs == 1
    end
  end

  describe "firefighters_by_person/1" do
    test "counts unplanned involvement per person" do
      records = [
        %{person_a: "a", person_b: "b", is_unplanned: true},
        %{person_a: "a", person_b: "c", is_unplanned: false},
        %{person_a: "b", person_b: "c", is_unplanned: true}
      ]

      fighters = PairingAnalysis.firefighters_by_person(records)
      alice = Enum.find(fighters, &(&1.person == "a"))
      assert alice.total == 2
      assert alice.unplanned == 1
    end
  end

  describe "firefighters_by_pair/1" do
    test "counts unplanned work per pair" do
      records = [
        %{person_a: "a", person_b: "b", is_unplanned: true},
        %{person_a: "a", person_b: "b", is_unplanned: false},
        %{person_a: "a", person_b: "b", is_unplanned: true}
      ]

      fighters = PairingAnalysis.firefighters_by_pair(records)
      assert length(fighters) == 1
      pair = hd(fighters)
      assert pair.pair == "a + b"
      assert pair.total == 3
      assert pair.unplanned == 2
    end
  end

  describe "interrupt_trend_by_week/1" do
    test "only counts unplanned records" do
      records = [
        %{person_a: "a", person_b: "b", is_unplanned: true, created_date: ~D[2024-01-08]},
        %{person_a: "a", person_b: "b", is_unplanned: false, created_date: ~D[2024-01-08]}
      ]

      trend = PairingAnalysis.interrupt_trend_by_week(records)
      assert length(trend) == 1
      assert hd(trend).interrupt_count == 1
    end

    test "returns empty for all planned records" do
      records = [
        %{person_a: "a", person_b: "b", is_unplanned: false, created_date: ~D[2024-01-08]}
      ]

      assert [] == PairingAnalysis.interrupt_trend_by_week(records)
    end
  end

  describe "interrupt_trend_by_person/1" do
    test "tracks per person over time" do
      records = [
        %{person_a: "a", person_b: "b", is_unplanned: true, created_date: ~D[2024-01-08]},
        %{person_a: "a", person_b: "c", is_unplanned: true, created_date: ~D[2024-01-08]}
      ]

      trend = PairingAnalysis.interrupt_trend_by_person(records)
      alice_records = Enum.filter(trend, &(&1.person == "a"))
      assert hd(alice_records).interrupt_count == 2
    end
  end
end
