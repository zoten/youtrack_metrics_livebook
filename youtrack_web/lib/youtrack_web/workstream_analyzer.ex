defmodule YoutrackWeb.WorkstreamAnalyzer do
  @moduledoc """
  Aggregates normalized issue effort into weekly workstream series for analyzer charts.
  """

  @type issue_result_t :: %{
          required(:issue_id) => String.t(),
          required(:status) => :mapped | :unmapped,
          required(:score) => float() | nil,
          optional(:source_field) => String.t() | nil,
          optional(:source_value) => term(),
          optional(:reason) => atom()
        }

  @type work_item_t :: %{
          required(:issue_id) => String.t(),
          required(:stream) => String.t(),
          optional(:start_at) => integer() | nil,
          optional(:end_at) => integer() | nil,
          optional(:resolved) => integer() | nil,
          optional(:status) => String.t()
        }

  @type build_result_t :: %{
          compare_series: [map()],
          composition_series: [map()],
          composition_totals: [map()],
          diagnostics: map()
        }

  @spec build([work_item_t()], [issue_result_t()], map(), keyword()) :: build_result_t()
  def build(work_items, normalized_results, rules, opts \\ []) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    selected_streams = Keyword.get(opts, :selected_streams, nil)
    parent_stream = Keyword.get(opts, :parent_stream, nil)
    direct_bucket = Keyword.get(opts, :direct_bucket, "(direct)")

    issue_windows = issue_windows(work_items, now_ms)
    issue_streams = issue_streams(work_items, rules)

    mapped_results =
      normalized_results
      |> Enum.filter(&(&1.status == :mapped and is_number(&1.score) and &1.score > 0.0))

    {contributions, anomaly_count} =
      mapped_results
      |> Enum.reduce({[], 0}, fn result, {acc, anomalies} ->
        with {:ok, window} <- fetch_window(issue_windows, result.issue_id),
             {:ok, stream} <- fetch_stream(issue_streams, result.issue_id),
             {:ok, weeks} <- active_weeks(window.start_ms, window.end_ms) do
          per_week = result.score / max(length(weeks), 1)

          rows =
            Enum.map(weeks, fn week ->
              %{
                issue_id: result.issue_id,
                stream: stream,
                week: week,
                effort: per_week
              }
            end)

          {rows ++ acc, anomalies}
        else
          _ -> {acc, anomalies + 1}
        end
      end)

    compare_series = build_compare_series(contributions, selected_streams)

    composition_series =
      build_composition_series(contributions, rules, parent_stream, direct_bucket)

    composition_totals =
      composition_series
      |> Enum.group_by(& &1.week)
      |> Enum.map(fn {week, rows} ->
        %{week: week, total_effort: Enum.sum(Enum.map(rows, & &1.effort))}
      end)
      |> Enum.sort_by(& &1.week)

    %{
      compare_series: compare_series,
      composition_series: composition_series,
      composition_totals: composition_totals,
      diagnostics: %{
        normalized_issue_count: length(mapped_results),
        attributed_issue_count:
          contributions |> Enum.map(& &1.issue_id) |> Enum.uniq() |> length(),
        attribution_anomaly_count: anomaly_count,
        compared_stream_count: compare_series |> Enum.map(& &1.stream) |> Enum.uniq() |> length(),
        composition_parent_stream: parent_stream
      }
    }
  end

  defp issue_windows(work_items, now_ms) do
    work_items
    |> Enum.group_by(& &1.issue_id)
    |> Map.new(fn {issue_id, items} ->
      starts = items |> Enum.map(&parse_ms(&1.start_at)) |> Enum.reject(&is_nil/1)

      end_candidates =
        items
        |> Enum.map(fn item ->
          parse_ms(item.end_at) || parse_ms(item.resolved) ||
            if(item.status == "ongoing", do: now_ms)
        end)
        |> Enum.reject(&is_nil/1)

      start_ms = if starts == [], do: nil, else: Enum.min(starts)
      end_ms = if end_candidates == [], do: nil, else: Enum.max(end_candidates)

      {issue_id, %{start_ms: start_ms, end_ms: end_ms}}
    end)
  end

  defp issue_streams(work_items, rules) do
    # When include_substreams is true, WorkItems.build creates work items for both
    # child streams and their parent streams for the same issue. We prefer the child
    # (substream) stream over the parent so that composition bucketing works correctly.
    substream_keys = rules |> Map.get(:substream_of, %{}) |> Map.keys() |> MapSet.new()

    work_items
    |> Enum.group_by(& &1.issue_id)
    |> Map.new(fn {issue_id, items} ->
      stream =
        items
        |> Enum.map(&(&1.stream || ""))
        |> Enum.reject(&(&1 == ""))
        |> Enum.frequencies()
        |> Enum.sort_by(fn {stream_name, count} ->
          # Prefer higher frequency, then prefer substream children over parents, then alphabetical
          is_parent = if MapSet.member?(substream_keys, stream_name), do: 0, else: 1
          {-count, is_parent, stream_name}
        end)
        |> List.first()
        |> case do
          {stream_name, _} -> stream_name
          nil -> nil
        end

      {issue_id, stream}
    end)
  end

  defp fetch_window(issue_windows, issue_id) do
    case Map.get(issue_windows, issue_id) do
      %{start_ms: start_ms, end_ms: end_ms} when is_integer(start_ms) and is_integer(end_ms) ->
        {:ok, %{start_ms: start_ms, end_ms: end_ms}}

      _ ->
        {:error, :missing_window}
    end
  end

  defp fetch_stream(issue_streams, issue_id) do
    case Map.get(issue_streams, issue_id) do
      stream when is_binary(stream) and stream != "" -> {:ok, stream}
      _ -> {:error, :missing_stream}
    end
  end

  defp active_weeks(start_ms, end_ms) when is_integer(start_ms) and is_integer(end_ms) do
    cond do
      end_ms < start_ms ->
        {:error, :negative_duration}

      true ->
        start_week =
          start_ms
          |> div(1000)
          |> DateTime.from_unix!()
          |> DateTime.to_date()
          |> Date.beginning_of_week(:monday)

        end_week =
          end_ms
          |> div(1000)
          |> DateTime.from_unix!()
          |> DateTime.to_date()
          |> Date.beginning_of_week(:monday)

        week_count = Date.diff(end_week, start_week) |> div(7)

        weeks =
          0..week_count
          |> Enum.map(fn offset ->
            start_week
            |> Date.add(offset * 7)
            |> Date.to_iso8601()
          end)

        {:ok, weeks}
    end
  end

  defp build_compare_series(contributions, selected_streams) do
    selected_set =
      case selected_streams do
        streams when is_list(streams) -> MapSet.new(streams)
        _ -> nil
      end

    contributions
    |> Enum.filter(fn row ->
      if selected_set do
        MapSet.member?(selected_set, row.stream)
      else
        true
      end
    end)
    |> Enum.group_by(&{&1.stream, &1.week})
    |> Enum.map(fn {{stream, week}, rows} ->
      %{stream: stream, week: week, effort: Enum.sum(Enum.map(rows, & &1.effort))}
    end)
    |> Enum.sort_by(&{&1.week, &1.stream})
  end

  defp build_composition_series(_contributions, _rules, nil, _direct_bucket), do: []

  defp build_composition_series(contributions, rules, parent_stream, direct_bucket) do
    descendants = descendants_of(rules, parent_stream)

    contributions
    |> Enum.reduce([], fn row, acc ->
      case bucket_for_stream(row.stream, parent_stream, descendants, direct_bucket) do
        nil -> acc
        bucket -> [%{week: row.week, substream: bucket, effort: row.effort} | acc]
      end
    end)
    |> Enum.group_by(&{&1.substream, &1.week})
    |> Enum.map(fn {{substream, week}, rows} ->
      %{substream: substream, week: week, effort: Enum.sum(Enum.map(rows, & &1.effort))}
    end)
    |> Enum.sort_by(&{&1.week, &1.substream})
  end

  defp bucket_for_stream(stream, parent_stream, descendants, direct_bucket) do
    cond do
      stream == parent_stream -> direct_bucket
      MapSet.member?(descendants, stream) -> stream
      true -> nil
    end
  end

  defp descendants_of(rules, parent_stream) do
    substream_of = Map.get(rules, :substream_of, %{})

    walk_descendants(substream_of, MapSet.new([parent_stream]), MapSet.new())
    |> MapSet.delete(parent_stream)
  end

  defp walk_descendants(substream_of, frontier, visited) do
    if MapSet.size(frontier) == 0 do
      visited
    else
      next =
        substream_of
        |> Enum.reduce(MapSet.new(), fn {child, parents}, acc ->
          if Enum.any?(parents, &MapSet.member?(frontier, &1)) and
               not MapSet.member?(visited, child) do
            MapSet.put(acc, child)
          else
            acc
          end
        end)

      walk_descendants(substream_of, next, MapSet.union(visited, next))
    end
  end

  defp parse_ms(value) when is_integer(value), do: value
  defp parse_ms(_), do: nil
end
