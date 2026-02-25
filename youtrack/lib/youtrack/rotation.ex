defmodule Youtrack.Rotation do
  @moduledoc """
  Analyzes workstream rotation patterns per person.

  Tracks how people move between workstreams over time, detecting
  back-and-forth patterns, computing tenure in each stream, and
  measuring rotation diversity.
  """

  @doc """
  Builds a rotation timeline for each person from work items.

  Returns a map of `%{person_login => [%{stream, week, item_count}]}` where
  each entry represents the person's primary stream for that week.
  """
  def timeline_by_person(work_items) do
    work_items
    |> Enum.filter(&is_integer(&1.start_at))
    |> Enum.group_by(& &1.person_login)
    |> Enum.map(fn {person, items} ->
      weekly =
        items
        |> Enum.map(fn wi ->
          date = DateTime.from_unix!(div(wi.start_at, 1000)) |> DateTime.to_date()
          week = Date.beginning_of_week(date, :monday)
          %{stream: wi.stream, week: week, issue_id: wi.issue_id}
        end)
        |> Enum.group_by(& &1.week)
        |> Enum.map(fn {week, week_items} ->
          stream_counts =
            week_items
            |> Enum.frequencies_by(& &1.stream)

          primary_stream =
            stream_counts
            |> Enum.max_by(fn {_s, c} -> c end)
            |> elem(0)

          all_streams = Map.keys(stream_counts)

          %{
            week: week,
            primary_stream: primary_stream,
            all_streams: all_streams,
            item_count: length(week_items)
          }
        end)
        |> Enum.sort_by(& &1.week)

      {person, weekly}
    end)
    |> Map.new()
  end

  @doc """
  Computes rotation metrics for each person.

  Returns a list of maps with:
  - `:person` — person login
  - `:total_weeks` — number of weeks with activity
  - `:unique_streams` — number of distinct streams worked on
  - `:switches` — number of primary stream changes between consecutive weeks
  - `:boomerang_rate` — % of switches that return to a previously visited stream
  - `:avg_tenure_weeks` — average consecutive weeks on the same primary stream
  - `:journey` — sequence of primary streams (e.g. "A → B → A → C")
  """
  def metrics_by_person(work_items) do
    timelines = timeline_by_person(work_items)

    timelines
    |> Enum.map(fn {person, weekly} ->
      streams_seq = Enum.map(weekly, & &1.primary_stream)

      unique_streams =
        streams_seq
        |> Enum.uniq()
        |> length()

      {switches, boomerangs} = compute_switches(streams_seq)

      boomerang_rate =
        if switches > 0, do: Float.round(boomerangs / switches * 100, 1), else: 0.0

      avg_tenure = compute_avg_tenure(streams_seq)

      journey = build_journey(streams_seq)

      %{
        person: person,
        total_weeks: length(weekly),
        unique_streams: unique_streams,
        switches: switches,
        boomerang_rate: boomerang_rate,
        avg_tenure_weeks: avg_tenure,
        journey: journey
      }
    end)
    |> Enum.sort_by(& &1.switches, :desc)
  end

  @doc """
  Computes person × week × stream data for heatmap visualization.

  Returns a flat list of maps with `:person`, `:week`, `:stream`, `:item_count`.
  """
  def person_week_stream(work_items) do
    work_items
    |> Enum.filter(&is_integer(&1.start_at))
    |> Enum.map(fn wi ->
      date = DateTime.from_unix!(div(wi.start_at, 1000)) |> DateTime.to_date()
      week = Date.beginning_of_week(date, :monday) |> Date.to_iso8601()
      %{person: wi.person_login, week: week, stream: wi.stream, issue_id: wi.issue_id}
    end)
    |> Enum.group_by(&{&1.person, &1.week})
    |> Enum.flat_map(fn {{person, week}, items} ->
      items
      |> Enum.frequencies_by(& &1.stream)
      |> Enum.map(fn {stream, count} ->
        %{person: person, week: week, stream: stream, item_count: count}
      end)
    end)
    |> Enum.sort_by(&{&1.person, &1.week})
  end

  @doc """
  Computes stream-level tenure statistics.

  Returns a list of maps with `:person`, `:stream`, `:total_weeks`, `:stints`
  (number of separate periods working on that stream).
  """
  def stream_tenure(work_items) do
    timelines = timeline_by_person(work_items)

    timelines
    |> Enum.flat_map(fn {person, weekly} ->
      streams_seq = Enum.map(weekly, & &1.primary_stream)

      streams_seq
      |> Enum.chunk_by(& &1)
      |> Enum.group_by(&hd/1)
      |> Enum.map(fn {stream, stints} ->
        total_weeks = stints |> Enum.map(&length/1) |> Enum.sum()

        %{
          person: person,
          stream: stream,
          total_weeks: total_weeks,
          stints: length(stints),
          avg_stint_weeks: Float.round(total_weeks / length(stints), 1)
        }
      end)
    end)
    |> Enum.sort_by(&{&1.person, -&1.total_weeks})
  end

  # Counts primary stream switches and boomerang switches (returning to a previously visited stream)
  defp compute_switches(streams_seq) when length(streams_seq) < 2, do: {0, 0}

  defp compute_switches(streams_seq) do
    streams_seq
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce({0, MapSet.new([hd(streams_seq)]), 0}, fn [prev, curr],
                                                             {switches, visited, boomerangs} ->
      if prev == curr do
        {switches, visited, boomerangs}
      else
        boomerang = if MapSet.member?(visited, curr), do: 1, else: 0
        {switches + 1, MapSet.put(visited, curr), boomerangs + boomerang}
      end
    end)
    |> then(fn {switches, _visited, boomerangs} -> {switches, boomerangs} end)
  end

  # Computes average consecutive weeks on the same primary stream
  defp compute_avg_tenure([]), do: 0.0

  defp compute_avg_tenure(streams_seq) do
    runs =
      streams_seq
      |> Enum.chunk_by(& &1)
      |> Enum.map(&length/1)

    if length(runs) > 0 do
      Float.round(Enum.sum(runs) / length(runs), 1)
    else
      0.0
    end
  end

  # Builds a condensed journey string like "A → B → A → C"
  defp build_journey([]), do: ""

  defp build_journey(streams_seq) do
    streams_seq
    |> Enum.chunk_by(& &1)
    |> Enum.map(&hd/1)
    |> Enum.join(" → ")
  end
end
