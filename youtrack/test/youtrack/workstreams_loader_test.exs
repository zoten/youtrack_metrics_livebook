defmodule Youtrack.WorkstreamsLoaderTest do
  use ExUnit.Case, async: true

  alias Youtrack.WorkstreamsLoader

  describe "transform_to_internal/1" do
    test "transforms simple workstream config" do
      yaml = %{
        "BACKEND" => %{
          "slugs" => ["BACKEND"],
          "tags" => ["team:backend"]
        }
      }

      rules = WorkstreamsLoader.transform_to_internal(yaml)

      assert rules.slug_prefix_to_stream == %{"BACKEND" => ["BACKEND"]}
      assert rules.tag_to_stream == %{"team:backend" => ["BACKEND"]}
      assert rules.substream_of == %{}
      assert rules.fallback == ["(unclassified)"]
    end

    test "handles multiple slugs for one workstream" do
      yaml = %{
        "API" => %{
          "slugs" => ["API", "REST API"]
        }
      }

      rules = WorkstreamsLoader.transform_to_internal(yaml)

      assert rules.slug_prefix_to_stream["API"] == ["API"]
      assert rules.slug_prefix_to_stream["REST API"] == ["API"]
    end

    test "handles substream_of" do
      yaml = %{
        "BACKEND" => %{"slugs" => ["BACKEND"]},
        "API" => %{
          "slugs" => ["API"],
          "substream_of" => ["BACKEND"]
        }
      }

      rules = WorkstreamsLoader.transform_to_internal(yaml)

      assert rules.substream_of == %{"API" => ["BACKEND"]}
    end

    test "handles nil config" do
      yaml = %{"BACKEND" => nil}

      rules = WorkstreamsLoader.transform_to_internal(yaml)

      assert rules.slug_prefix_to_stream == %{}
      assert rules.tag_to_stream == %{}
    end

    test "ignores empty substream_of list" do
      yaml = %{
        "BACKEND" => %{
          "slugs" => ["BACKEND"],
          "substream_of" => []
        }
      }

      rules = WorkstreamsLoader.transform_to_internal(yaml)

      assert rules.substream_of == %{}
    end

    test "handles missing slugs and tags" do
      yaml = %{
        "API" => %{
          "substream_of" => ["PARENT"]
        }
      }

      rules = WorkstreamsLoader.transform_to_internal(yaml)

      assert rules.slug_prefix_to_stream == %{}
      assert rules.tag_to_stream == %{}
      assert rules.substream_of == %{"API" => ["PARENT"]}
    end
  end

  describe "empty_rules/0" do
    test "returns valid empty rules structure" do
      rules = WorkstreamsLoader.empty_rules()

      assert rules.slug_prefix_to_stream == %{}
      assert rules.tag_to_stream == %{}
      assert rules.substream_of == %{}
      assert rules.fallback == ["(unclassified)"]
    end
  end

  describe "load_file/1" do
    test "returns error tuple for non-existent file" do
      assert {:error, _} = WorkstreamsLoader.load_file("/nonexistent/file.yaml")
    end
  end
end
