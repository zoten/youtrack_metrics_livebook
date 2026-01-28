defmodule Youtrack.FieldsTest do
  use ExUnit.Case, async: true

  alias Youtrack.Fields

  describe "custom_field_value/2" do
    test "returns field value when found" do
      issue = %{
        "customFields" => [
          %{"name" => "State", "value" => %{"name" => "In Progress"}},
          %{"name" => "Priority", "value" => %{"name" => "High"}}
        ]
      }

      assert %{"name" => "In Progress"} = Fields.custom_field_value(issue, "State")
    end

    test "returns nil when field not found" do
      issue = %{"customFields" => [%{"name" => "State", "value" => %{"name" => "Open"}}]}
      assert nil == Fields.custom_field_value(issue, "NonExistent")
    end

    test "returns nil when customFields is nil" do
      issue = %{"customFields" => nil}
      assert nil == Fields.custom_field_value(issue, "State")
    end

    test "returns nil when customFields is missing" do
      issue = %{}
      assert nil == Fields.custom_field_value(issue, "State")
    end
  end

  describe "state_name/2" do
    test "extracts state name from issue" do
      issue = %{
        "customFields" => [%{"name" => "State", "value" => %{"name" => "In Progress"}}]
      }

      assert "In Progress" == Fields.state_name(issue, "State")
    end

    test "returns nil when state value has no name" do
      issue = %{
        "customFields" => [%{"name" => "State", "value" => nil}]
      }

      assert nil == Fields.state_name(issue, "State")
    end
  end

  describe "assignees/2" do
    test "returns list for single assignee" do
      issue = %{
        "customFields" => [
          %{"name" => "Assignee", "value" => %{"login" => "john", "name" => "John Doe"}}
        ]
      }

      assert [%{"login" => "john", "name" => "John Doe"}] = Fields.assignees(issue, "Assignee")
    end

    test "returns list for multiple assignees" do
      issue = %{
        "customFields" => [
          %{
            "name" => "Assignees",
            "value" => [
              %{"login" => "john", "name" => "John"},
              %{"login" => "jane", "name" => "Jane"}
            ]
          }
        ]
      }

      assignees = Fields.assignees(issue, "Assignees")
      assert length(assignees) == 2
      assert Enum.any?(assignees, &(&1["login"] == "john"))
    end

    test "returns empty list when no assignees" do
      issue = %{"customFields" => [%{"name" => "Assignee", "value" => nil}]}
      assert [] == Fields.assignees(issue, "Assignee")
    end

    test "filters out non-map values from assignee list" do
      issue = %{
        "customFields" => [
          %{"name" => "Assignees", "value" => [%{"login" => "john"}, nil, "invalid"]}
        ]
      }

      assert [%{"login" => "john"}] = Fields.assignees(issue, "Assignees")
    end
  end

  describe "project/1" do
    test "extracts project short name" do
      issue = %{"project" => %{"shortName" => "MYPROJ"}}
      assert "MYPROJ" == Fields.project(issue)
    end

    test "returns unknown when project missing" do
      issue = %{}
      assert "unknown" == Fields.project(issue)
    end

    test "returns unknown when shortName missing" do
      issue = %{"project" => %{}}
      assert "unknown" == Fields.project(issue)
    end
  end

  describe "tags/1" do
    test "extracts tag names" do
      issue = %{
        "tags" => [
          %{"name" => "app:finance"},
          %{"name" => "priority:high"}
        ]
      }

      tags = Fields.tags(issue)
      assert "app:finance" in tags
      assert "priority:high" in tags
    end

    test "returns empty list when no tags" do
      issue = %{"tags" => nil}
      assert [] == Fields.tags(issue)
    end

    test "filters out nil tag names" do
      issue = %{"tags" => [%{"name" => "valid"}, %{"name" => nil}, %{}]}
      assert ["valid"] == Fields.tags(issue)
    end
  end
end
