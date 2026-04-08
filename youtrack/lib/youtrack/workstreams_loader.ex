defmodule Youtrack.WorkstreamsLoader do
  @moduledoc """
  Loads workstream mappings from YAML configuration files.

  ## YAML Format

      BACKEND:
        slugs:
          - BACKEND
        tags:
          - team:backend
        types:
          - Task
          - Bug
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
    * `:type_to_stream` - Maps issue types to workstream names
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

      iex> yaml = %{"BACKEND" => %{"slugs" => ["BACKEND"], "tags" => ["team:backend"], "types" => ["Task"]}}
      iex> Youtrack.WorkstreamsLoader.transform_to_internal(yaml)
      %{
        slug_prefix_to_stream: %{"BACKEND" => ["BACKEND"]},
        tag_to_stream: %{"team:backend" => ["BACKEND"]},
        type_to_stream: %{"Task" => ["BACKEND"]},
        substream_of: %{},
        fallback: ["(unclassified)"]
      }
  """
  def transform_to_internal(yaml) when is_map(yaml) do
    {slug_map, tag_map, type_map, substream_map} =
      Enum.reduce(yaml, {%{}, %{}, %{}, %{}}, fn {stream_name, config},
                                                 {slugs_acc, tags_acc, types_acc, sub_acc} ->
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

        types_acc =
          (config["types"] || [])
          |> Enum.reduce(types_acc, fn type, acc ->
            Map.put(acc, type, stream_list)
          end)

        sub_acc =
          case config["substream_of"] do
            nil -> sub_acc
            [] -> sub_acc
            parents when is_list(parents) -> Map.put(sub_acc, stream_name, parents)
          end

        {slugs_acc, tags_acc, types_acc, sub_acc}
      end)

    %{
      slug_prefix_to_stream: slug_map,
      tag_to_stream: tag_map,
      type_to_stream: type_map,
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
      type_to_stream: %{},
      substream_of: %{},
      fallback: ["(unclassified)"]
    }
  end

  @doc """
  Finds and loads workstream rules from standard file locations.

  Searches for `workstreams.yaml` in the current directory and `/data/`,
  falling back to `workstreams.example.yaml`. Returns empty rules if nothing is found.

  Returns `{rules, path}` where `path` is the file that was loaded, or `nil`.
  """
  def load_from_default_paths do
    path = find_default_path()

    if path do
      {load_file!(path), path}
    else
      {empty_rules(), nil}
    end
  end

  @doc """
  Reads raw YAML text from a file.

  Returns `{:ok, yaml_string}` or `{:error, reason}`.
  """
  def load_file_raw(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, :file.format_error(reason) |> to_string()}
    end
  end

  @doc """
  Finds and returns the raw YAML text from standard file locations.

  Returns `{:ok, yaml_string, path}` or `{:error, :not_found}`.
  """
  def load_raw_from_default_paths do
    case find_default_path() do
      nil -> {:error, :not_found}
      path ->
        case load_file_raw(path) do
          {:ok, content} -> {:ok, content, path}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Validates `yaml_string` by parsing it, then writes it to `path`.

  Returns `:ok` or `{:error, reason}`.
  """
  def save_to_file(yaml_string, path) when is_binary(yaml_string) and is_binary(path) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, _parsed} ->
        case File.write(path, yaml_string) do
          :ok -> :ok
          {:error, reason} -> {:error, :file.format_error(reason) |> to_string()}
        end

      {:error, %{message: message}} ->
        {:error, message}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Adds a slug-to-stream mapping to the YAML file at `path`.

  Reads the existing YAML, adds or updates the slug under the given stream entry,
  serializes back to YAML and writes the file.

  Returns `{:ok, rules, yaml_string}` or `{:error, reason}`.
  """
  def add_slug_to_stream(slug, stream, path) when is_binary(slug) and is_binary(stream) and is_binary(path) do
    normalized_slug = slug |> String.trim() |> String.upcase() |> String.replace(~r/\s+/, " ")
    normalized_stream = String.trim(stream)

    with {:ok, content} <- load_file_raw(path),
         {:ok, raw_yaml} <- YamlElixir.read_from_string(content) do
      raw_yaml = if is_map(raw_yaml), do: raw_yaml, else: %{}

      updated_yaml =
        Map.update(raw_yaml, normalized_stream, %{"slugs" => [normalized_slug]}, fn existing ->
          existing = if is_map(existing), do: existing, else: %{}
          current_slugs = existing["slugs"] || []

          updated_slugs =
            if normalized_slug in current_slugs do
              current_slugs
            else
              current_slugs ++ [normalized_slug]
            end

          Map.put(existing, "slugs", updated_slugs)
        end)

      yaml_string = to_yaml(updated_yaml)

      case File.write(path, yaml_string) do
        :ok ->
          {:ok, transform_to_internal(updated_yaml), yaml_string}

        {:error, reason} ->
          {:error, :file.format_error(reason) |> to_string()}
      end
    end
  end

  # Serializes a raw YAML map (as parsed by YamlElixir) back to a YAML string.
  # Workstream entries are sorted alphabetically; slug/tag/type lists are sorted too.
  defp to_yaml(raw_yaml) when is_map(raw_yaml) do
    raw_yaml
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(&entry_to_yaml/1)
    |> Enum.join("\n")
  end

  defp entry_to_yaml({name, config}) when is_nil(config) or config == %{} do
    "#{yaml_key(name)}: {}\n"
  end

  defp entry_to_yaml({name, config}) when is_map(config) do
    field_order = ["slugs", "tags", "types", "substream_of"]

    field_lines =
      field_order
      |> Enum.flat_map(fn field ->
        case config[field] do
          nil -> []
          [] -> []
          items when is_list(items) ->
            sorted = Enum.sort(items)
            ["  #{field}:"] ++ Enum.map(sorted, &"    - #{yaml_scalar(&1)}")
        end
      end)

    if field_lines == [] do
      "#{yaml_key(name)}: {}\n"
    else
      ([yaml_key(name) <> ":"] ++ field_lines)
      |> Enum.join("\n")
      |> Kernel.<>("\n")
    end
  end

  # Quotes a scalar value if it contains characters that need quoting in YAML.
  defp yaml_scalar(value) when is_binary(value) do
    needs_quoting =
      String.contains?(value, [":", "#", "[", "]", "{", "}", ",", "&", "*", "?", "|", "-",
                                "<", ">", "=", "!", "%", "@", "`"]) or
        String.starts_with?(value, [" ", "\"", "'"]) or
        String.ends_with?(value, [" "])

    if needs_quoting do
      escaped = String.replace(value, "\"", "\\\"")
      "\"#{escaped}\""
    else
      value
    end
  end

  defp yaml_key(value) when is_binary(value), do: yaml_scalar(value)

  defp find_default_path do
    Enum.find(
      [
        "workstreams.yaml",
        "/data/workstreams.yaml",
        "workstreams.example.yaml",
        "/data/workstreams.example.yaml"
      ],
      &File.exists?/1
    )
  end
end
