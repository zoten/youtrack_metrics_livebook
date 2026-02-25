defmodule Youtrack.WorkItemsTest do
  use ExUnit.Case, async: true

  alias Youtrack.WorkItems

  @rules %{
    slug_prefix_to_stream: %{"BACKEND" => ["BACKEND"], "API" => ["API"]},
    tag_to_stream: %{"TEAM:BACKEND" => ["BACKEND"]},
    substream_of: %{"API" => ["BACKEND"]},
    fallback: ["(unclassified)"]
  }

  defp make_issue(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "issue-1",
        "idReadable" => "PROJ-1",
        "summary" => "[BACKEND] Fix bug",
        "created" => 1_700_000_000_000,
        "resolved" => nil,
        "customFields" => [
          %{"name" => "State", "value" => %{"name" => "Open"}},
          %{
            "name" => "Assignee",
            "value" => %{"login" => "alice", "name" => "Alice"}
          }
        ],
        "tags" => []
      },
      overrides
    )
  end

  @default_opts [
    state_field: "State",
    assignees_field: "Assignee",
    rules: @rules,
    in_progress_names: ["In Progress"]
  ]

  describe "build/2" do
    test "creates work items from issues" do
      issues = [make_issue()]
      items = WorkItems.build(issues, @default_opts)

      assert length(items) == 1
      item = hd(items)
      assert item.issue_id == "PROJ-1"
      assert item.person_login == "alice"
      assert item.stream == "BACKEND"
      assert item.status == "unfinished"
    end

    test "explodes issue into multiple work items per assignee" do
      issue =
        make_issue(%{
          "customFields" => [
            %{"name" => "State", "value" => %{"name" => "Open"}},
            %{
              "name" => "Assignee",
              "value" => [
                %{"login" => "alice", "name" => "Alice"},
                %{"login" => "bob", "name" => "Bob"}
              ]
            }
          ]
        })

      items = WorkItems.build([issue], @default_opts)
      logins = Enum.map(items, & &1.person_login) |> Enum.sort()
      assert "alice" in logins
      assert "bob" in logins
    end

    test "excludes specified logins" do
      issue =
        make_issue(%{
          "customFields" => [
            %{"name" => "State", "value" => %{"name" => "Open"}},
            %{
              "name" => "Assignee",
              "value" => [
                %{"login" => "alice", "name" => "Alice"},
                %{"login" => "bot", "name" => "Bot"}
              ]
            }
          ]
        })

      opts = Keyword.put(@default_opts, :excluded_logins, ["bot"])
      items = WorkItems.build([issue], opts)
      assert length(items) == 1
      assert hd(items).person_login == "alice"
    end

    test "returns empty list when all assignees are excluded" do
      issue = make_issue()
      opts = Keyword.put(@default_opts, :excluded_logins, ["alice"])
      assert [] == WorkItems.build([issue], opts)
    end

    test "classifies finished issues correctly" do
      issue = make_issue(%{"resolved" => 1_700_100_000_000})
      items = WorkItems.build([issue], @default_opts)
      assert hd(items).status == "finished"
    end

    test "classifies ongoing issues correctly" do
      issue =
        make_issue(%{
          "customFields" => [
            %{"name" => "State", "value" => %{"name" => "In Progress"}},
            %{"name" => "Assignee", "value" => %{"login" => "alice", "name" => "Alice"}}
          ]
        })

      items = WorkItems.build([issue], @default_opts)
      assert hd(items).status == "ongoing"
    end

    test "tags unplanned work items" do
      issue =
        make_issue(%{
          "tags" => [%{"name" => "on the ankles"}]
        })

      opts = Keyword.put(@default_opts, :unplanned_tag, "on the ankles")
      items = WorkItems.build([issue], opts)
      assert hd(items).is_unplanned
    end

    test "unplanned tag match is case-insensitive" do
      issue =
        make_issue(%{
          "tags" => [%{"name" => "On The Ankles"}]
        })

      opts = Keyword.put(@default_opts, :unplanned_tag, "on the ankles")
      items = WorkItems.build([issue], opts)
      assert hd(items).is_unplanned
    end

    test "planned items have falsy is_unplanned" do
      issue = make_issue()
      opts = Keyword.put(@default_opts, :unplanned_tag, "on the ankles")
      items = WorkItems.build([issue], opts)
      refute hd(items).is_unplanned
    end

    test "uses issue_start_at map when provided" do
      issue = make_issue()
      start_time = 1_699_900_000_000

      opts = Keyword.put(@default_opts, :issue_start_at, %{"issue-1" => start_time})
      items = WorkItems.build([issue], opts)
      assert hd(items).start_at == start_time
    end

    test "falls back to created when no issue_start_at" do
      issue = make_issue()
      items = WorkItems.build([issue], @default_opts)
      assert hd(items).start_at == 1_700_000_000_000
    end

    test "expands substreams to parents when include_substreams is true" do
      issue =
        make_issue(%{
          "summary" => "[API] New endpoint"
        })

      opts = Keyword.put(@default_opts, :include_substreams, true)
      items = WorkItems.build([issue], opts)
      streams = Enum.map(items, & &1.stream) |> Enum.sort()
      assert "API" in streams
      assert "BACKEND" in streams
    end

    test "does not expand substreams when include_substreams is false" do
      issue =
        make_issue(%{
          "summary" => "[API] New endpoint"
        })

      opts = Keyword.put(@default_opts, :include_substreams, false)
      items = WorkItems.build([issue], opts)
      streams = Enum.map(items, & &1.stream)
      assert streams == ["API"]
    end
  end
end
