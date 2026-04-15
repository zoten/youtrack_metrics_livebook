defmodule YoutrackWeb.EffortNormalization do
  @moduledoc """
  Resolves generic effort scores for issues from configured mapping rules.
  """

  alias Youtrack.Fields

  @type issue_result_t :: %{
          issue_id: String.t(),
          status: :mapped | :unmapped,
          score: float() | nil,
          source_field: String.t() | nil,
          source_value: term() | nil,
          reason: atom()
        }

  @spec normalize_issue(map(), map()) :: issue_result_t()
  def normalize_issue(issue, mappings) when is_map(issue) and is_map(mappings) do
    candidates = Map.get(mappings, :field_candidates, [])
    rules = Map.get(mappings, :rules, %{})
    fallback = get_in(mappings, [:fallback, :strategy]) || :unmapped
    issue_id = issue["idReadable"] || issue["id"] || "(unknown)"

    outcome =
      Enum.reduce_while(candidates, nil, fn field_name, acc ->
        raw_value = Fields.custom_field_value(issue, field_name)

        case scalar_value(raw_value) do
          :missing ->
            {:cont, acc}

          {:value, source_value} ->
            case Map.get(rules, field_name) do
              nil ->
                {:cont, acc || {:unmapped, field_name, source_value, :missing_rule}}

              %{type: :numeric} = rule ->
                case resolve_numeric(source_value, rule) do
                  {:ok, score} ->
                    {:halt, {:mapped, field_name, source_value, score}}

                  {:error, reason} ->
                    {:cont, acc || {:unmapped, field_name, source_value, reason}}
                end

              %{type: :enum} = rule ->
                case resolve_enum(source_value, rule) do
                  {:ok, score} ->
                    {:halt, {:mapped, field_name, source_value, score}}

                  {:error, reason} ->
                    {:cont, acc || {:unmapped, field_name, source_value, reason}}
                end

              _ ->
                {:cont, acc || {:unmapped, field_name, source_value, :invalid_rule}}
            end

          {:invalid, reason} ->
            {:cont, acc || {:unmapped, field_name, inspect(raw_value), reason}}
        end
      end)

    case outcome do
      {:mapped, field_name, source_value, score} ->
        %{
          issue_id: issue_id,
          status: :mapped,
          score: score,
          source_field: field_name,
          source_value: source_value,
          reason: :mapped
        }

      {:unmapped, field_name, source_value, reason} ->
        if fallback == :zero do
          %{
            issue_id: issue_id,
            status: :mapped,
            score: 0.0,
            source_field: field_name,
            source_value: source_value,
            reason: :fallback_zero
          }
        else
          %{
            issue_id: issue_id,
            status: :unmapped,
            score: nil,
            source_field: field_name,
            source_value: source_value,
            reason: reason
          }
        end

      nil ->
        if fallback == :zero do
          %{
            issue_id: issue_id,
            status: :mapped,
            score: 0.0,
            source_field: nil,
            source_value: nil,
            reason: :fallback_zero
          }
        else
          %{
            issue_id: issue_id,
            status: :unmapped,
            score: nil,
            source_field: nil,
            source_value: nil,
            reason: :no_candidate_value
          }
        end
    end
  end

  @spec normalize_issues([map()], map()) :: %{results: [issue_result_t()], diagnostics: map()}
  def normalize_issues(issues, mappings) when is_list(issues) and is_map(mappings) do
    results = Enum.map(issues, &normalize_issue(&1, mappings))

    mapped = Enum.filter(results, &(&1.status == :mapped))
    unmapped = Enum.filter(results, &(&1.status == :unmapped))

    diagnostics = %{
      issue_count: length(results),
      mapped_count: length(mapped),
      unmapped_count: length(unmapped),
      mapped_by_field:
        mapped
        |> Enum.reject(&is_nil(&1.source_field))
        |> Enum.frequencies_by(& &1.source_field),
      unmapped_by_reason: Enum.frequencies_by(unmapped, & &1.reason),
      unmapped_samples:
        unmapped
        |> Enum.take(10)
        |> Enum.map(fn item ->
          %{
            issue_id: item.issue_id,
            source_field: item.source_field,
            source_value: item.source_value,
            reason: item.reason
          }
        end)
    }

    %{results: results, diagnostics: diagnostics}
  end

  defp scalar_value(nil), do: :missing
  defp scalar_value(value) when is_integer(value), do: {:value, value}
  defp scalar_value(value) when is_float(value), do: {:value, value}

  defp scalar_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: :missing, else: {:value, trimmed}
  end

  defp scalar_value(%{"name" => value}) when is_binary(value), do: scalar_value(value)
  defp scalar_value(%{"value" => value}), do: scalar_value(value)
  defp scalar_value(_), do: {:invalid, :unsupported_value_shape}

  defp resolve_numeric(source_value, %{min: min_value}) do
    with {:ok, score} <- parse_number(source_value),
         true <- score >= min_value do
      {:ok, score}
    else
      false -> {:error, :below_minimum}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_enum(source_value, %{map: enum_map}) do
    key = source_value |> to_string() |> String.trim() |> String.downcase()

    case Map.fetch(enum_map, key) do
      {:ok, score} -> {:ok, score}
      :error -> {:error, :enum_value_unmapped}
    end
  end

  defp parse_number(value) when is_integer(value), do: {:ok, value * 1.0}
  defp parse_number(value) when is_float(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_numeric_value}
    end
  end

  defp parse_number(_), do: {:error, :invalid_numeric_value}
end
