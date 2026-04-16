defmodule YoutrackWeb.WorkstreamAnalyzerTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.EffortNormalization
  alias YoutrackWeb.WorkstreamAnalyzer

  test "splits effort across touched ISO weeks and preserves per-issue total" do
    work_items = [
      %{
        issue_id: "PROJ-1",
        stream: "Backend",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-17 12:00:00Z]),
        status: "finished"
      }
    ]

    normalized_results = [
      %{issue_id: "PROJ-1", status: :mapped, score: 9.0, reason: :mapped}
    ]

    result =
      WorkstreamAnalyzer.build(work_items, normalized_results, %{}, selected_streams: ["Backend"])

    backend_rows = Enum.filter(result.compare_series, &(&1.stream == "Backend"))

    assert length(backend_rows) == 3

    total = backend_rows |> Enum.map(& &1.effort) |> Enum.sum()
    assert_in_delta total, 9.0, 0.000001
  end

  test "compare mode filters selected streams" do
    work_items = [
      %{
        issue_id: "PROJ-2",
        stream: "Backend",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 18:00:00Z]),
        status: "finished"
      },
      %{
        issue_id: "PROJ-3",
        stream: "Frontend",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 18:00:00Z]),
        status: "finished"
      }
    ]

    normalized_results = [
      %{issue_id: "PROJ-2", status: :mapped, score: 2.0, reason: :mapped},
      %{issue_id: "PROJ-3", status: :mapped, score: 3.0, reason: :mapped}
    ]

    result =
      WorkstreamAnalyzer.build(work_items, normalized_results, %{},
        selected_streams: ["Frontend"]
      )

    assert Enum.map(result.compare_series, & &1.stream) |> Enum.uniq() == ["Frontend"]
  end

  test "composition mode includes parent direct work and descendants only" do
    work_items = [
      %{
        issue_id: "PROJ-4",
        stream: "Platform",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 18:00:00Z]),
        status: "finished"
      },
      %{
        issue_id: "PROJ-5",
        stream: "API",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 18:00:00Z]),
        status: "finished"
      },
      %{
        issue_id: "PROJ-6",
        stream: "Web",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 18:00:00Z]),
        status: "finished"
      }
    ]

    normalized_results = [
      %{issue_id: "PROJ-4", status: :mapped, score: 5.0, reason: :mapped},
      %{issue_id: "PROJ-5", status: :mapped, score: 3.0, reason: :mapped},
      %{issue_id: "PROJ-6", status: :mapped, score: 2.0, reason: :mapped}
    ]

    rules = %{substream_of: %{"API" => ["Platform"], "Web" => ["Frontend"]}}

    result =
      WorkstreamAnalyzer.build(work_items, normalized_results, rules,
        selected_streams: ["Platform", "API", "Web"],
        parent_stream: "Platform"
      )

    buckets = result.composition_series |> Enum.map(& &1.substream) |> Enum.uniq() |> Enum.sort()
    assert buckets == ["(direct)", "API"]

    total = result.composition_totals |> Enum.map(& &1.total_effort) |> Enum.sum()
    assert_in_delta total, 8.0, 0.000001
  end

  test "counts attribution anomalies when timestamps are invalid or missing" do
    work_items = [
      %{
        issue_id: "PROJ-7",
        stream: "Backend",
        start_at: dt_ms(~U[2024-06-04 10:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 10:00:00Z]),
        status: "finished"
      },
      %{
        issue_id: "PROJ-8",
        stream: "Backend",
        start_at: nil,
        end_at: dt_ms(~U[2024-06-03 10:00:00Z]),
        status: "finished"
      }
    ]

    normalized_results = [
      %{issue_id: "PROJ-7", status: :mapped, score: 2.0, reason: :mapped},
      %{issue_id: "PROJ-8", status: :mapped, score: 2.0, reason: :mapped}
    ]

    result =
      WorkstreamAnalyzer.build(work_items, normalized_results, %{}, selected_streams: ["Backend"])

    assert result.compare_series == []
    assert result.diagnostics.attribution_anomaly_count == 2
    assert result.diagnostics.attributed_issue_count == 0
  end

  test "end-to-end mixed historical schemes normalize and aggregate predictably" do
    issues = [
      issue_fixture("PROJ-11", %{"Story Points" => 8}),
      issue_fixture("PROJ-12", %{"Size" => "medium"}),
      issue_fixture("PROJ-13", %{"T-Shirt" => "XL"})
    ]

    mappings = %{
      field_candidates: ["Story Points", "Size", "T-Shirt"],
      rules: %{
        "Story Points" => %{type: :numeric, min: 0.0},
        "Size" => %{type: :enum, map: %{"medium" => 3.0}}
      },
      fallback: %{strategy: :unmapped}
    }

    normalization = EffortNormalization.normalize_issues(issues, mappings)

    assert normalization.diagnostics.mapped_count == 2
    assert normalization.diagnostics.unmapped_count == 1
    assert normalization.diagnostics.unmapped_by_reason == %{missing_rule: 1}
    assert Enum.any?(normalization.diagnostics.unmapped_samples, &(&1.issue_id == "PROJ-13"))

    work_items = [
      %{
        issue_id: "PROJ-11",
        stream: "Backend",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-17 09:00:00Z]),
        status: "finished"
      },
      %{
        issue_id: "PROJ-12",
        stream: "Frontend",
        start_at: dt_ms(~U[2024-06-10 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-10 18:00:00Z]),
        status: "finished"
      },
      %{
        issue_id: "PROJ-13",
        stream: "Backend",
        start_at: dt_ms(~U[2024-06-10 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-10 18:00:00Z]),
        status: "finished"
      }
    ]

    result =
      WorkstreamAnalyzer.build(work_items, normalization.results, %{},
        selected_streams: ["Backend", "Frontend"]
      )

    backend_total =
      result.compare_series
      |> Enum.filter(&(&1.stream == "Backend"))
      |> Enum.map(& &1.effort)
      |> Enum.sum()

    frontend_total =
      result.compare_series
      |> Enum.filter(&(&1.stream == "Frontend"))
      |> Enum.map(& &1.effort)
      |> Enum.sum()

    assert_in_delta backend_total, 8.0, 0.000001
    assert_in_delta frontend_total, 3.0, 0.000001
    assert result.diagnostics.normalized_issue_count == 2
    assert result.diagnostics.attributed_issue_count == 2
  end

  test "composition mode prefers substream over parent when include_substreams creates duplicate work items" do
    # When WorkItems.build runs with include_substreams: true, a PBDX issue gets
    # work items for BOTH "PBDX" and "AFR". Previously, issue_streams picked "AFR"
    # (alphabetically first), causing all substream issues to appear as "(direct)".
    work_items = [
      %{
        issue_id: "PBDX-1",
        stream: "PBDX",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 18:00:00Z]),
        status: "finished"
      },
      %{
        issue_id: "PBDX-1",
        stream: "AFR",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 18:00:00Z]),
        status: "finished"
      }
    ]

    normalized_results = [
      %{issue_id: "PBDX-1", status: :mapped, score: 5.0, reason: :mapped}
    ]

    rules = %{substream_of: %{"PBDX" => ["AFR"], "CBDX" => ["AFR"]}}

    result =
      WorkstreamAnalyzer.build(work_items, normalized_results, rules, parent_stream: "AFR")

    # PBDX-1 must appear under "PBDX", not "(direct)"
    buckets = result.composition_series |> Enum.map(& &1.substream) |> Enum.uniq()
    assert buckets == ["PBDX"]
    refute "(direct)" in buckets

    total = result.composition_totals |> Enum.map(& &1.total_effort) |> Enum.sum()
    assert_in_delta total, 5.0, 0.000001
  end

  test "composition mode correctly isolates multiple independent hierarchies" do
    # This test reproduces the issue: when there are two separate parent hierarchies,
    # descendants of one parent should not appear under the other parent.
    # Hierarchy 1: AFR > {PBDX, CBDX, FFA, ANAGRAFICA}
    # Hierarchy 2: SUPPORT > {ACTUARIAL-L2}

    work_items = [
      %{
        issue_id: "PBDX-100",
        stream: "PBDX",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 18:00:00Z]),
        status: "finished"
      },
      %{
        issue_id: "FFA-200",
        stream: "FFA",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 18:00:00Z]),
        status: "finished"
      },
      %{
        issue_id: "ANAGRAFICA-300",
        stream: "ANAGRAFICA",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 18:00:00Z]),
        status: "finished"
      },
      %{
        issue_id: "ACT-400",
        stream: "ACTUARIAL-L2",
        start_at: dt_ms(~U[2024-06-03 09:00:00Z]),
        end_at: dt_ms(~U[2024-06-03 18:00:00Z]),
        status: "finished"
      }
    ]

    normalized_results = [
      %{issue_id: "PBDX-100", status: :mapped, score: 5.0, reason: :mapped},
      %{issue_id: "FFA-200", status: :mapped, score: 2.0, reason: :mapped},
      %{issue_id: "ANAGRAFICA-300", status: :mapped, score: 3.0, reason: :mapped},
      %{issue_id: "ACT-400", status: :mapped, score: 4.0, reason: :mapped}
    ]

    rules = %{
      substream_of: %{
        "PBDX" => ["AFR"],
        "CBDX" => ["AFR"],
        "FFA" => ["AFR"],
        "ANAGRAFICA" => ["AFR"],
        "ACTUARIAL-L2" => ["SUPPORT"]
      }
    }

    # Test 1: When viewing AFR composition, only AFR's children should appear
    result_afr =
      WorkstreamAnalyzer.build(work_items, normalized_results, rules, parent_stream: "AFR")

    buckets_afr = result_afr.composition_series |> Enum.map(& &1.substream) |> Enum.uniq()

    # All AFR children should appear
    assert "PBDX" in buckets_afr
    assert "FFA" in buckets_afr
    assert "ANAGRAFICA" in buckets_afr
    # ACTUARIAL-L2 should NOT appear (it belongs to SUPPORT, not AFR)
    assert "ACTUARIAL-L2" not in buckets_afr

    # Test 2: When viewing SUPPORT composition, only ACTUARIAL-L2 should appear
    result_support =
      WorkstreamAnalyzer.build(work_items, normalized_results, rules, parent_stream: "SUPPORT")

    buckets_support =
      result_support.composition_series |> Enum.map(& &1.substream) |> Enum.uniq()

    # Only SUPPORT's child should appear
    assert "ACTUARIAL-L2" in buckets_support
    # AFR's children should NOT appear (they belong to AFR, not SUPPORT)
    assert "PBDX" not in buckets_support
    assert "FFA" not in buckets_support
    assert "ANAGRAFICA" not in buckets_support
  end

  defp issue_fixture(issue_id, field_values) do
    custom_fields =
      Enum.map(field_values, fn {field_name, value} ->
        %{"name" => field_name, "value" => value}
      end)

    %{
      "idReadable" => issue_id,
      "customFields" => custom_fields
    }
  end

  defp dt_ms(datetime), do: DateTime.to_unix(datetime, :millisecond)
end
