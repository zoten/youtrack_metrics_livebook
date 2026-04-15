defmodule YoutrackWeb.EffortNormalizationTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.EffortNormalization

  test "normalize_issue/2 supports numeric passthrough" do
    mappings = %{
      field_candidates: ["Story Points"],
      rules: %{"Story Points" => %{type: :numeric, min: 0.0}},
      fallback: %{strategy: :unmapped}
    }

    issue = issue_fixture("ISSUE-1", %{"Story Points" => 5})

    assert EffortNormalization.normalize_issue(issue, mappings) == %{
             issue_id: "ISSUE-1",
             status: :mapped,
             score: 5.0,
             source_field: "Story Points",
             source_value: 5,
             reason: :mapped
           }
  end

  test "normalize_issue/2 supports enum mapping" do
    mappings = %{
      field_candidates: ["Size"],
      rules: %{"Size" => %{type: :enum, map: %{"easy" => 1.0, "medium" => 3.0, "hard" => 5.0}}},
      fallback: %{strategy: :unmapped}
    }

    issue = issue_fixture("ISSUE-2", %{"Size" => %{"name" => "Medium"}})
    result = EffortNormalization.normalize_issue(issue, mappings)

    assert result.status == :mapped
    assert result.score == 3.0
    assert result.source_field == "Size"
    assert result.source_value == "Medium"
  end

  test "normalize_issue/2 uses first valid candidate by order" do
    mappings = %{
      field_candidates: ["Story Points", "Size"],
      rules: %{
        "Story Points" => %{type: :numeric, min: 0.0},
        "Size" => %{type: :enum, map: %{"easy" => 1.0, "medium" => 3.0, "hard" => 5.0}}
      },
      fallback: %{strategy: :unmapped}
    }

    issue =
      issue_fixture("ISSUE-3", %{
        "Story Points" => "not-a-number",
        "Size" => "hard"
      })

    result = EffortNormalization.normalize_issue(issue, mappings)

    assert result.status == :mapped
    assert result.score == 5.0
    assert result.source_field == "Size"
  end

  test "normalize_issue/2 marks issue as unmapped when no candidates resolve" do
    mappings = %{
      field_candidates: ["Story Points", "Size"],
      rules: %{"Story Points" => %{type: :numeric, min: 0.0}},
      fallback: %{strategy: :unmapped}
    }

    issue = issue_fixture("ISSUE-4", %{"Size" => "hard"})
    result = EffortNormalization.normalize_issue(issue, mappings)

    assert result.status == :unmapped
    assert result.score == nil
    assert result.reason == :missing_rule
    assert result.source_field == "Size"
  end

  test "normalize_issues/2 returns diagnostics summary" do
    mappings = %{
      field_candidates: ["Story Points", "Size"],
      rules: %{
        "Story Points" => %{type: :numeric, min: 0.0},
        "Size" => %{type: :enum, map: %{"medium" => 3.0}}
      },
      fallback: %{strategy: :unmapped}
    }

    issues = [
      issue_fixture("ISSUE-5", %{"Story Points" => 8}),
      issue_fixture("ISSUE-6", %{"Size" => "medium"}),
      issue_fixture("ISSUE-7", %{"Size" => "unknown"})
    ]

    result = EffortNormalization.normalize_issues(issues, mappings)

    assert result.diagnostics.issue_count == 3
    assert result.diagnostics.mapped_count == 2
    assert result.diagnostics.unmapped_count == 1
    assert result.diagnostics.mapped_by_field == %{"Size" => 1, "Story Points" => 1}
    assert result.diagnostics.unmapped_by_reason == %{enum_value_unmapped: 1}
    assert length(result.diagnostics.unmapped_samples) == 1
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
end
