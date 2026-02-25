defmodule Youtrack.PairingAnalysis do
  @moduledoc """
  Extracts and analyzes pairing patterns from YouTrack issues.

  Identifies which team members frequently work together, how pairing trends evolve
  over time, and how pairing is distributed across workstreams.
  """

  alias Youtrack.{Fields, Workstreams}

  @doc """
  Extracts pair records from issues with 2+ assignees.

  Each record represents one pair × workstream combination with metadata.

  ## Options

    * `:assignees_field` - Name of the assignees custom field
    * `:excluded_logins` - Logins to exclude (default: `[]`)
    * `:workstream_rules` - Workstream rules map
    * `:include_substreams` - Whether to expand to parent workstreams (default: `true`)
    * `:unplanned_tag` - Tag marking unplanned work (default: `nil`)
  """
  def extract_pairs(issues, opts) do
    assignees_field = opts[:assignees_field]
    excluded_logins = opts[:excluded_logins] || []
    workstream_rules = opts[:workstream_rules]
    include_substreams = Keyword.get(opts, :include_substreams, true)
    unplanned_tag = opts[:unplanned_tag]

    issues
    |> Enum.flat_map(fn issue ->
      assignees =
        Fields.assignees(issue, assignees_field)
        |> Enum.map(fn a -> a["login"] || a["name"] || "unknown" end)
        |> Enum.reject(&(&1 in excluded_logins))
        |> Enum.sort()

      project = Fields.project(issue)

      streams =
        Workstreams.streams_for_issue(issue, workstream_rules,
          include_substreams: include_substreams
        )

      created = issue["created"]

      tags = Fields.tags(issue)

      is_unplanned =
        unplanned_tag &&
          Enum.any?(tags, fn t ->
            String.downcase(t) == String.downcase(unplanned_tag)
          end)

      case assignees do
        [_ | _] = list when length(list) >= 2 ->
          pairs = for a <- list, b <- list, a < b, do: {a, b}

          for {a, b} <- pairs, stream <- streams do
            %{
              person_a: a,
              person_b: b,
              issue_id: issue["idReadable"] || issue["id"],
              project: project,
              workstream: stream,
              created: created,
              created_date: created && Date.from_iso8601!(date_from_ms(created)),
              is_unplanned: is_unplanned
            }
          end

        _ ->
          []
      end
    end)
  end

  defp date_from_ms(ms) when is_integer(ms) do
    DateTime.from_unix!(div(ms, 1000)) |> DateTime.to_date() |> Date.to_iso8601()
  end

  @doc """
  Builds a symmetric pair matrix showing collaboration frequency.

  Returns a list of maps with `:person_a`, `:person_b`, and `:count`.
  """
  def pair_matrix(pair_records) do
    pair_records
    |> Enum.reduce(%{}, fn %{person_a: a, person_b: b}, acc ->
      acc
      |> Map.update({a, b}, 1, &(&1 + 1))
      |> Map.update({b, a}, 1, &(&1 + 1))
    end)
    |> Enum.map(fn {{a, b}, count} ->
      %{person_a: a, person_b: b, count: count}
    end)
  end

  @doc """
  Groups pair records by week and returns trend data.

  Returns a list of maps with `:week`, `:pair_count`, and `:unique_pairs`.
  """
  def trend_by_week(pair_records) do
    pair_records
    |> Enum.group_by(fn %{created_date: d} ->
      d && Date.beginning_of_week(d, :monday)
    end)
    |> Enum.reject(fn {week, _} -> is_nil(week) end)
    |> Enum.map(fn {week, records} ->
      unique_pairs = records |> Enum.map(&{&1.person_a, &1.person_b}) |> Enum.uniq() |> length()

      %{
        week: Date.to_iso8601(week),
        pair_count: length(records),
        unique_pairs: unique_pairs
      }
    end)
    |> Enum.sort_by(& &1.week)
  end

  @doc """
  Groups pair records by workstream.

  Returns a list of maps with `:workstream`, `:pair_count`, and `:unique_pairs`.
  """
  def by_workstream(pair_records) do
    pair_records
    |> Enum.group_by(& &1.workstream)
    |> Enum.map(fn {workstream, records} ->
      unique_pairs = records |> Enum.map(&{&1.person_a, &1.person_b}) |> Enum.uniq() |> length()

      %{
        workstream: workstream,
        pair_count: length(records),
        unique_pairs: unique_pairs
      }
    end)
    |> Enum.sort_by(& &1.pair_count, :desc)
  end

  @doc """
  Identifies firefighters: people with high unplanned work involvement.

  Returns a list of maps with `:person`, `:total`, `:unplanned`, and `:unplanned_pct`.
  """
  def firefighters_by_person(pair_records) do
    all_people =
      pair_records
      |> Enum.flat_map(fn r -> [r.person_a, r.person_b] end)
      |> Enum.uniq()

    Enum.map(all_people, fn person ->
      involved =
        Enum.filter(pair_records, fn r ->
          r.person_a == person or r.person_b == person
        end)

      total = length(involved)
      unplanned = Enum.count(involved, & &1.is_unplanned)
      pct = if total > 0, do: Float.round(unplanned / total * 100, 1), else: 0.0

      %{person: person, total: total, unplanned: unplanned, unplanned_pct: pct}
    end)
    |> Enum.sort_by(& &1.unplanned, :desc)
  end

  @doc """
  Identifies firefighter pairs: pairs with high unplanned work involvement.

  Returns a list of maps with `:pair`, `:total`, `:unplanned`, and `:unplanned_pct`.
  """
  def firefighters_by_pair(pair_records) do
    pair_records
    |> Enum.group_by(&{&1.person_a, &1.person_b})
    |> Enum.map(fn {{a, b}, records} ->
      total = length(records)
      unplanned = Enum.count(records, & &1.is_unplanned)
      pct = if total > 0, do: Float.round(unplanned / total * 100, 1), else: 0.0

      %{pair: "#{a} + #{b}", total: total, unplanned: unplanned, unplanned_pct: pct}
    end)
    |> Enum.sort_by(& &1.unplanned, :desc)
  end

  @doc """
  Tracks unplanned pair work aggregated by week.
  """
  def interrupt_trend_by_week(pair_records) do
    pair_records
    |> Enum.filter(& &1.is_unplanned)
    |> Enum.group_by(fn %{created_date: d} ->
      d && Date.beginning_of_week(d, :monday)
    end)
    |> Enum.reject(fn {week, _} -> is_nil(week) end)
    |> Enum.map(fn {week, records} ->
      %{
        week: Date.to_iso8601(week),
        interrupt_count: length(records)
      }
    end)
    |> Enum.sort_by(& &1.week)
  end

  @doc """
  Tracks unplanned pair work per person over time (weekly).
  """
  def interrupt_trend_by_person(pair_records) do
    unplanned = Enum.filter(pair_records, & &1.is_unplanned)

    all_people =
      unplanned
      |> Enum.flat_map(fn r -> [r.person_a, r.person_b] end)
      |> Enum.uniq()

    Enum.flat_map(all_people, fn person ->
      involved =
        Enum.filter(unplanned, fn r ->
          r.person_a == person or r.person_b == person
        end)

      involved
      |> Enum.group_by(fn %{created_date: d} ->
        d && Date.beginning_of_week(d, :monday)
      end)
      |> Enum.reject(fn {week, _} -> is_nil(week) end)
      |> Enum.map(fn {week, records} ->
        %{
          person: person,
          week: Date.to_iso8601(week),
          interrupt_count: length(records)
        }
      end)
    end)
    |> Enum.sort_by(&{&1.week, &1.person})
  end
end
