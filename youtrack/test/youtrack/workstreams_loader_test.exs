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
      assert rules.tag_to_stream == %{"TEAM:BACKEND" => ["BACKEND"]}
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

    test "uppercases tag keys so they match streams_for_issue lookup" do
      yaml = %{
        "INFOSEC" => %{
          "tags" => ["sec:app", "sec:issue"]
        }
      }

      rules = WorkstreamsLoader.transform_to_internal(yaml)

      assert Map.has_key?(rules.tag_to_stream, "SEC:APP")
      assert Map.has_key?(rules.tag_to_stream, "SEC:ISSUE")
      refute Map.has_key?(rules.tag_to_stream, "sec:app")
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

  # ──────────────────────────────────────────────────────────────────────────
  # New persistence helpers

  defp tmp_yaml(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "workstreams_test_#{:erlang.unique_integer([:positive])}.yaml"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "load_file_raw/1" do
    test "returns {:ok, content} for an existing file" do
      path = tmp_yaml("BACKEND:\n  slugs:\n    - BACKEND\n")
      assert {:ok, content} = WorkstreamsLoader.load_file_raw(path)
      assert String.contains?(content, "BACKEND")
    end

    test "returns {:error, reason} for a missing file" do
      assert {:error, _reason} = WorkstreamsLoader.load_file_raw("/nonexistent/path/file.yaml")
    end
  end

  describe "save_to_file/2" do
    test "writes valid YAML to disk and returns :ok" do
      path = tmp_yaml("")
      yaml = "BACKEND:\n  slugs:\n    - BACKEND\n"
      assert :ok = WorkstreamsLoader.save_to_file(yaml, path)
      assert File.read!(path) == yaml
    end

    test "returns {:error, reason} for invalid YAML" do
      path = tmp_yaml("")
      assert {:error, _reason} = WorkstreamsLoader.save_to_file("key: [unclosed", path)
    end
  end

  describe "add_slug_to_stream/3" do
    test "creates a new stream entry when stream does not exist" do
      path = tmp_yaml("{}\n")

      assert {:ok, rules, yaml_string} =
               WorkstreamsLoader.add_slug_to_stream("NEWSLUG", "NEWSTREAM", path)

      assert Map.get(rules.slug_prefix_to_stream, "NEWSLUG") == ["NEWSTREAM"]
      assert String.contains?(yaml_string, "NEWSTREAM")
      assert String.contains?(yaml_string, "NEWSLUG")
    end

    test "adds a new slug to an existing stream entry" do
      path =
        tmp_yaml("""
        BACKEND:
          slugs:
            - BACKEND
        """)

      assert {:ok, rules, yaml_string} =
               WorkstreamsLoader.add_slug_to_stream("BE", "BACKEND", path)

      assert Map.has_key?(rules.slug_prefix_to_stream, "BE")
      assert rules.slug_prefix_to_stream["BE"] == ["BACKEND"]
      assert String.contains?(yaml_string, "BE")
    end

    test "normalizes slug to uppercase" do
      path = tmp_yaml("{}\n")

      assert {:ok, rules, _yaml} =
               WorkstreamsLoader.add_slug_to_stream("backend", "BACKEND", path)

      assert Map.has_key?(rules.slug_prefix_to_stream, "BACKEND")
    end

    test "does not duplicate a slug already present in the stream's slugs list" do
      path =
        tmp_yaml("""
        BACKEND:
          slugs:
            - BACKEND
        """)

      assert {:ok, rules, _yaml} =
               WorkstreamsLoader.add_slug_to_stream("BACKEND", "BACKEND", path)

      slug_lists =
        rules.slug_prefix_to_stream
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&(&1 == "BACKEND"))

      assert length(slug_lists) == 1
    end

    test "persists the change to disk" do
      path = tmp_yaml("{}\n")
      WorkstreamsLoader.add_slug_to_stream("TEST", "TESTSTREAM", path)
      content = File.read!(path)
      assert String.contains?(content, "TEST")
      assert String.contains?(content, "TESTSTREAM")
    end
  end
end
