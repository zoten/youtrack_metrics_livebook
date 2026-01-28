defmodule Youtrack.WorkstreamsTest do
  use ExUnit.Case, async: true

  alias Youtrack.Workstreams

  describe "summary_slug/1" do
    test "extracts slug from bracketed prefix" do
      assert "BACKEND" == Workstreams.summary_slug("[BACKEND] Fix the bug")
    end

    test "extracts slug with spaces" do
      assert "REST API" == Workstreams.summary_slug("[REST API] Update report")
    end

    test "handles leading whitespace" do
      assert "BACKEND" == Workstreams.summary_slug("  [BACKEND] Fix the bug")
    end

    test "returns nil when no bracket prefix" do
      assert nil == Workstreams.summary_slug("No slug here")
    end

    test "returns nil for nil input" do
      assert nil == Workstreams.summary_slug(nil)
    end

    test "returns empty string for empty brackets" do
      # Empty brackets capture empty string, which trims to empty
      assert nil == Workstreams.summary_slug("[] Empty")
    end
  end

  describe "normalize_slug/1" do
    test "uppercases and trims slug" do
      assert "BACKEND" == Workstreams.normalize_slug("  backend  ")
    end

    test "collapses multiple spaces" do
      assert "REST API" == Workstreams.normalize_slug("rest   api")
    end

    test "returns nil for nil input" do
      assert nil == Workstreams.normalize_slug(nil)
    end
  end

  describe "canonical_slug/1" do
    test "normalizes slug" do
      assert "BACKEND" == Workstreams.canonical_slug("  backend  ")
    end

    test "returns (no slug) for nil" do
      assert "(no slug)" == Workstreams.canonical_slug(nil)
    end
  end

  describe "issue_tags/1" do
    test "extracts tag names" do
      issue = %{"tags" => [%{"name" => "team:frontend"}, %{"name" => "urgent"}]}
      assert ["team:frontend", "urgent"] == Workstreams.issue_tags(issue)
    end

    test "filters out non-string names" do
      issue = %{"tags" => [%{"name" => "valid"}, %{"name" => nil}, %{}]}
      assert ["valid"] == Workstreams.issue_tags(issue)
    end

    test "returns empty list when no tags" do
      issue = %{"tags" => nil}
      assert [] == Workstreams.issue_tags(issue)
    end
  end

  describe "streams_for_issue/3" do
    setup do
      rules = %{
        slug_prefix_to_stream: %{
          "BACKEND" => ["BACKEND"],
          "REST API" => ["API"]
        },
        tag_to_stream: %{
          "TEAM:FRONTEND" => ["FRONTEND"]
        },
        substream_of: %{
          "API" => ["BACKEND"]
        },
        fallback: ["(unclassified)"]
      }

      {:ok, rules: rules}
    end

    test "matches by slug", %{rules: rules} do
      issue = %{"summary" => "[BACKEND] Fix bug", "tags" => []}
      assert ["BACKEND"] == Workstreams.streams_for_issue(issue, rules)
    end

    test "matches by tag", %{rules: rules} do
      issue = %{"summary" => "No slug", "tags" => [%{"name" => "team:frontend"}]}
      assert ["FRONTEND"] == Workstreams.streams_for_issue(issue, rules)
    end

    test "combines slug and tag matches", %{rules: rules} do
      issue = %{"summary" => "[BACKEND] Fix", "tags" => [%{"name" => "team:frontend"}]}
      streams = Workstreams.streams_for_issue(issue, rules)
      assert "BACKEND" in streams
      assert "FRONTEND" in streams
    end

    test "expands to parent workstreams by default", %{rules: rules} do
      issue = %{"summary" => "[REST API] Update", "tags" => []}
      streams = Workstreams.streams_for_issue(issue, rules)
      assert "API" in streams
      assert "BACKEND" in streams
    end

    test "does not expand when include_substreams is false", %{rules: rules} do
      issue = %{"summary" => "[REST API] Update", "tags" => []}
      streams = Workstreams.streams_for_issue(issue, rules, include_substreams: false)
      assert streams == ["API"]
    end

    test "returns fallback for unclassified issues", %{rules: rules} do
      issue = %{"summary" => "No classification", "tags" => []}
      assert ["(unclassified)"] == Workstreams.streams_for_issue(issue, rules)
    end
  end

  describe "expand_to_parents/2" do
    test "adds parent workstreams" do
      rules = %{substream_of: %{"API" => ["BACKEND"], "DATABASE" => ["BACKEND"]}}
      streams = ["API", "OTHER"]

      expanded = Workstreams.expand_to_parents(streams, rules)
      assert "API" in expanded
      assert "BACKEND" in expanded
      assert "OTHER" in expanded
    end

    test "handles missing substream_of map" do
      rules = %{}
      streams = ["BACKEND"]

      assert ["BACKEND"] == Workstreams.expand_to_parents(streams, rules)
    end

    test "deduplicates results" do
      rules = %{substream_of: %{"API" => ["BACKEND"], "DATABASE" => ["BACKEND"]}}
      streams = ["API", "DATABASE"]

      expanded = Workstreams.expand_to_parents(streams, rules)
      backend_count = Enum.count(expanded, &(&1 == "BACKEND"))
      assert backend_count == 1
    end
  end

  describe "parse_rules!/1" do
    test "normalizes slug keys to uppercase" do
      text = """
      %{
        slug_prefix_to_stream: %{"backend" => ["BACKEND"], "rest api" => ["API"]},
        tag_to_stream: %{"team:frontend" => ["FRONTEND"]},
        substream_of: %{},
        fallback: ["(unclassified)"]
      }
      """

      rules = Workstreams.parse_rules!(text)
      assert Map.has_key?(rules.slug_prefix_to_stream, "BACKEND")
      assert Map.has_key?(rules.slug_prefix_to_stream, "REST API")
      assert Map.has_key?(rules.tag_to_stream, "TEAM:FRONTEND")
    end

    test "preserves substream_of" do
      text = """
      %{
        slug_prefix_to_stream: %{},
        tag_to_stream: %{},
        substream_of: %{"API" => ["BACKEND"]},
        fallback: ["(unclassified)"]
      }
      """

      rules = Workstreams.parse_rules!(text)
      assert rules.substream_of == %{"API" => ["BACKEND"]}
    end
  end
end
