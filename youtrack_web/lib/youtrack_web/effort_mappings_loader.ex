defmodule YoutrackWeb.EffortMappingsLoader do
  @moduledoc """
  Loads and validates effort normalization mappings from YAML.

  Internal normalized format:

      %{
        field_candidates: ["Story Points", "Size"],
        rules: %{
          "Story Points" => %{type: :numeric, min: 0.0},
          "Size" => %{type: :enum, map: %{"easy" => 1.0, "medium" => 3.0}}
        },
        fallback: %{strategy: :unmapped}
      }
  """

  @type mappings_t :: %{
          field_candidates: [String.t()],
          rules: %{optional(String.t()) => map()},
          fallback: %{strategy: :unmapped | :zero}
        }

  @spec load_file!(String.t()) :: mappings_t()
  def load_file!(path) do
    case load_file(path) do
      {:ok, mappings} -> mappings
      {:error, reason} -> raise RuntimeError, "failed to load effort mappings: #{reason}"
    end
  end

  @spec load_file(String.t()) :: {:ok, mappings_t()} | {:error, String.t()}
  def load_file(path) when is_binary(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} -> transform_to_internal(yaml)
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @spec transform_to_internal(map() | nil) :: {:ok, mappings_t()} | {:error, String.t()}
  def transform_to_internal(yaml) when is_map(yaml) do
    field_candidates =
      yaml
      |> Map.get("field_candidates", [])
      |> normalize_field_candidates()

    with {:ok, rules} <- normalize_rules(Map.get(yaml, "rules", %{})),
         {:ok, fallback} <- normalize_fallback(Map.get(yaml, "fallback", %{})) do
      {:ok,
       %{
         field_candidates: field_candidates,
         rules: rules,
         fallback: fallback
       }}
    end
  end

  def transform_to_internal(nil), do: {:ok, empty_mappings()}
  def transform_to_internal(_), do: {:error, "effort mappings root must be a map"}

  @spec empty_mappings() :: mappings_t()
  def empty_mappings do
    %{
      field_candidates: [],
      rules: %{},
      fallback: %{strategy: :unmapped}
    }
  end

  @spec load_from_default_paths() :: {mappings_t(), String.t() | nil}
  def load_from_default_paths do
    path = find_default_path()

    if path do
      case load_file(path) do
        {:ok, mappings} -> {mappings, path}
        {:error, _reason} -> {empty_mappings(), path}
      end
    else
      {empty_mappings(), nil}
    end
  end

  defp normalize_field_candidates(candidates) when is_list(candidates) do
    candidates
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_field_candidates(_), do: []

  defp normalize_rules(rules) when is_map(rules) do
    rules
    |> Enum.reduce_while({:ok, %{}}, fn {field_name, raw_rule}, {:ok, acc} ->
      field_name = to_string(field_name) |> String.trim()

      if field_name == "" do
        {:halt, {:error, "rules contains an empty field name"}}
      else
        case normalize_rule(field_name, raw_rule) do
          {:ok, normalized_rule} -> {:cont, {:ok, Map.put(acc, field_name, normalized_rule)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp normalize_rules(_), do: {:error, "rules must be a map"}

  defp normalize_rule(field_name, %{"type" => "numeric"} = rule) do
    min =
      case Map.get(rule, "min", 0) do
        nil -> 0.0
        value -> value
      end

    with {:ok, min_value} <- parse_number(min) do
      {:ok, %{type: :numeric, min: min_value}}
    else
      {:error, _} -> {:error, "numeric rule for #{field_name} has invalid min"}
    end
  end

  defp normalize_rule(field_name, %{"type" => "enum", "map" => enum_map}) when is_map(enum_map) do
    enum_map
    |> Enum.reduce_while({:ok, %{}}, fn {raw_key, raw_score}, {:ok, acc} ->
      key = raw_key |> to_string() |> String.trim() |> String.downcase()

      cond do
        key == "" ->
          {:halt, {:error, "enum rule for #{field_name} contains an empty key"}}

        true ->
          case parse_number(raw_score) do
            {:ok, score} -> {:cont, {:ok, Map.put(acc, key, score)}}
            {:error, _} -> {:halt, {:error, "enum rule for #{field_name} has non-numeric score"}}
          end
      end
    end)
    |> case do
      {:ok, normalized_map} -> {:ok, %{type: :enum, map: normalized_map}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_rule(field_name, %{"type" => "enum"}) do
    {:error, "enum rule for #{field_name} must define a map"}
  end

  defp normalize_rule(field_name, %{"type" => type}) do
    {:error, "unsupported rule type for #{field_name}: #{inspect(type)}"}
  end

  defp normalize_rule(field_name, _rule) do
    {:error, "rule for #{field_name} must be a map with a type"}
  end

  defp normalize_fallback(%{"strategy" => strategy}) when strategy in ["unmapped", "zero"] do
    {:ok, %{strategy: String.to_atom(strategy)}}
  end

  defp normalize_fallback(%{}) do
    {:ok, %{strategy: :unmapped}}
  end

  defp normalize_fallback(_), do: {:error, "fallback must be a map"}

  defp parse_number(value) when is_integer(value), do: {:ok, value * 1.0}
  defp parse_number(value) when is_float(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_number}
    end
  end

  defp parse_number(_), do: {:error, :invalid_number}

  defp find_default_path do
    Enum.find(
      [
        "effort_mappings.yaml",
        "/data/effort_mappings.yaml",
        "effort_mappings.example.yaml",
        "/data/effort_mappings.example.yaml"
      ],
      &File.exists?/1
    )
  end

  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason), do: inspect(reason)
end
