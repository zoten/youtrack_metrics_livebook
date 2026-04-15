defmodule YoutrackWeb.EffortMappingsLoaderTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.EffortMappingsLoader

  test "transform_to_internal/1 normalizes numeric and enum rules" do
    yaml = %{
      "field_candidates" => ["Story Points", "Size"],
      "rules" => %{
        "Story Points" => %{"type" => "numeric", "min" => 1},
        "Size" => %{
          "type" => "enum",
          "map" => %{"easy" => 1, "medium" => "3", "hard" => 5}
        }
      },
      "fallback" => %{"strategy" => "unmapped"}
    }

    assert {:ok, mappings} = EffortMappingsLoader.transform_to_internal(yaml)

    assert mappings.field_candidates == ["Story Points", "Size"]
    assert mappings.rules["Story Points"] == %{type: :numeric, min: 1.0}

    assert mappings.rules["Size"] == %{
             type: :enum,
             map: %{"easy" => 1.0, "hard" => 5.0, "medium" => 3.0}
           }

    assert mappings.fallback == %{strategy: :unmapped}
  end

  test "transform_to_internal/1 rejects invalid enum scores" do
    yaml = %{
      "field_candidates" => ["Size"],
      "rules" => %{
        "Size" => %{"type" => "enum", "map" => %{"medium" => "abc"}}
      }
    }

    assert {:error, reason} = EffortMappingsLoader.transform_to_internal(yaml)
    assert reason =~ "non-numeric score"
  end

  test "empty_mappings/0 returns safe defaults" do
    assert EffortMappingsLoader.empty_mappings() == %{
             field_candidates: [],
             rules: %{},
             fallback: %{strategy: :unmapped}
           }
  end
end
