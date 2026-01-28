defmodule Youtrack.WorkstreamsLoader do
  @moduledoc """
  Loads workstream mappings from YAML configuration files.

  ## YAML Format

      BACKEND:
        slugs:
          - BACKEND
        tags:
          - team:backend
      API:
        slugs:
          - API
          - REST API
        substream_of:
          - BACKEND

  ## Internal Format

  Returns a map with:

    * `:slug_prefix_to_stream` - Maps normalized slugs to workstream names
    * `:tag_to_stream` - Maps tags to workstream names
    * `:substream_of` - Maps workstreams to their parent workstreams
    * `:fallback` - Default workstream for unclassified issues
  """

  @doc """
  Loads workstream config from a YAML file. Raises on error.
  """
  def load_file!(path) do
    path
    |> YamlElixir.read_from_file!()
    |> transform_to_internal()
  end

  @doc """
  Loads workstream config from a YAML file. Returns `{:ok, rules}` or `{:error, reason}`.
  """
  def load_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} -> {:ok, transform_to_internal(yaml)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Transforms a parsed YAML map into the internal rules format.

  ## Examples

      iex> yaml = %{"BACKEND" => %{"slugs" => ["BACKEND"], "tags" => ["team:backend"]}}
      iex> Youtrack.WorkstreamsLoader.transform_to_internal(yaml)
      %{
        slug_prefix_to_stream: %{"BACKEND" => ["BACKEND"]},
        tag_to_stream: %{"team:backend" => ["BACKEND"]},
        substream_of: %{},
        fallback: ["(unclassified)"]
      }
  """
  def transform_to_internal(yaml) when is_map(yaml) do
    {slug_map, tag_map, substream_map} =
      Enum.reduce(yaml, {%{}, %{}, %{}}, fn {stream_name, config},
                                            {slugs_acc, tags_acc, sub_acc} ->
        config = config || %{}
        stream_list = [stream_name]

        slugs_acc =
          (config["slugs"] || [])
          |> Enum.reduce(slugs_acc, fn slug, acc ->
            Map.put(acc, slug, stream_list)
          end)

        tags_acc =
          (config["tags"] || [])
          |> Enum.reduce(tags_acc, fn tag, acc ->
            Map.put(acc, tag, stream_list)
          end)

        sub_acc =
          case config["substream_of"] do
            nil -> sub_acc
            [] -> sub_acc
            parents when is_list(parents) -> Map.put(sub_acc, stream_name, parents)
          end

        {slugs_acc, tags_acc, sub_acc}
      end)

    %{
      slug_prefix_to_stream: slug_map,
      tag_to_stream: tag_map,
      substream_of: substream_map,
      fallback: ["(unclassified)"]
    }
  end

  @doc """
  Returns an empty rules structure for when no config file exists.
  """
  def empty_rules do
    %{
      slug_prefix_to_stream: %{},
      tag_to_stream: %{},
      substream_of: %{},
      fallback: ["(unclassified)"]
    }
  end
end
