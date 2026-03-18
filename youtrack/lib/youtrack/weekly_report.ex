defmodule Youtrack.WeeklyReport do
  @moduledoc """
  Builds structured data for weekly and daily digest reports.

  This module provides:
  - Checklist extraction from issue descriptions (markdown `- [ ]` / `- [x]` syntax)
  - Net active time computation, excluding periods when "on hold" or "blocked" tags are active
  - Per-issue structured summaries combining state changes, comments, and checklist state
  - Duration formatting utilities
  """

  alias Youtrack.{Fields, Status}

  # ---------------------------------------------------------------------------
  # Checklist extraction
  # ---------------------------------------------------------------------------

  @doc """
  Extracts markdown checkbox items from an issue description.

  Scans for lines matching `- [ ]` (unchecked) or `- [x]` / `- [X]` (checked).

  Returns a map with `:checked` count, `:unchecked` count, and `:items` list
  of `{:checked | :unchecked, text}` tuples. Returns all-zero counts when the
  description is nil or empty.

  ## Examples

      iex> Youtrack.WeeklyReport.extract_checklist("- [x] Done\\n- [ ] Todo")
      %{checked: 1, unchecked: 1, items: [checked: "Done", unchecked: "Todo"]}
  """
  def extract_checklist(nil), do: %{checked: 0, unchecked: 0, items: []}
  def extract_checklist(""), do: %{checked: 0, unchecked: 0, items: []}

  def extract_checklist(description) when is_binary(description) do
    items =
      description
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        trimmed = String.trim(line)

        cond do
          String.match?(trimmed, ~r/^- \[[xX]\]/) ->
            text = Regex.replace(~r/^- \[[xX]\]\s*/, trimmed, "")
            [{:checked, text}]

          String.match?(trimmed, ~r/^- \[ \]/) ->
            text = Regex.replace(~r/^- \[ \]\s*/, trimmed, "")
            [{:unchecked, text}]

          true ->
            []
        end
      end)

    checked = Enum.count(items, &(elem(&1, 0) == :checked))
    unchecked = Enum.count(items, &(elem(&1, 0) == :unchecked))
    %{checked: checked, unchecked: unchecked, items: items}
  end

  # ---------------------------------------------------------------------------
  # Net active time
  # ---------------------------------------------------------------------------

  @doc """
  Computes the net active time in milliseconds for an issue, excluding periods
  when any of `hold_tags` were active as tags on the issue.

  The function replays all tag activities to determine when hold-state tags were
  applied and removed, then subtracts those periods from the total
  `[start_ms, end_ms]` window.

  ## Parameters

  - `start_ms` – when the issue entered active work (e.g., first "In Progress")
  - `end_ms` – when the issue finished (resolved) or current time if still open
  - `activities` – full activity list for the issue, including `TagCategory` events
  - `hold_tags` – list of tag names (case-insensitive) that pause active time,
    e.g. `["on hold", "blocked"]`

  Returns `nil` when `start_ms` or `end_ms` is nil.
  """
  def net_active_time(start_ms, end_ms, activities, hold_tags)
      when is_integer(start_ms) and is_integer(end_ms) do
    hold_lower = MapSet.new(Enum.map(hold_tags, &String.downcase/1))

    tag_events =
      activities
      |> Enum.filter(fn a -> get_in(a, ["field", "name"]) == "tags" end)
      |> Enum.sort_by(& &1["timestamp"])

    # Replay all tag events up to start_ms to find the initial hold state
    active_holds_at_start =
      Enum.reduce(tag_events, MapSet.new(), fn act, acc ->
        if act["timestamp"] <= start_ms do
          added = hold_names(act["added"], hold_lower)
          removed = hold_names(act["removed"], hold_lower)
          acc |> MapSet.union(added) |> MapSet.difference(removed)
        else
          acc
        end
      end)

    in_hold_at_start = not Enum.empty?(active_holds_at_start)
    initial_hold_start = if in_hold_at_start, do: start_ms, else: nil

    # Walk through events in (start_ms, end_ms] and accumulate paused duration
    {total_paused, in_hold_final, hold_start_final} =
      tag_events
      |> Enum.filter(fn a -> a["timestamp"] > start_ms and a["timestamp"] <= end_ms end)
      |> Enum.reduce({0, in_hold_at_start, initial_hold_start}, fn act,
                                                                   {acc, in_hold, hold_start} ->
        ts = act["timestamp"]
        any_added = not Enum.empty?(hold_names(act["added"], hold_lower))
        any_removed = not Enum.empty?(hold_names(act["removed"], hold_lower))

        cond do
          not in_hold and any_added ->
            {acc, true, ts}

          in_hold and any_removed ->
            paused = max(0, ts - hold_start)
            {acc + paused, false, nil}

          true ->
            {acc, in_hold, hold_start}
        end
      end)

    # Add remaining hold time if still on hold when the window closes
    final_paused =
      if in_hold_final and is_integer(hold_start_final) do
        total_paused + max(0, end_ms - hold_start_final)
      else
        total_paused
      end

    max(0, end_ms - start_ms - final_paused)
  end

  def net_active_time(_start_ms, _end_ms, _activities, _hold_tags), do: nil

  # ---------------------------------------------------------------------------
  # Duration formatting
  # ---------------------------------------------------------------------------

  @doc """
  Formats a duration given in milliseconds as a human-readable string.

  Uses calendar hours (24h/day) as timestamps are wall-clock times.
  Returns `"N/A"` for nil and `"< 1h"` for very short durations.

  ## Examples

      iex> Youtrack.WeeklyReport.format_duration(90_000_000)
      "1d 1h"
  """
  def format_duration(nil), do: "N/A"
  def format_duration(ms) when is_integer(ms) and ms <= 0, do: "< 1h"

  def format_duration(ms) when is_integer(ms) do
    hours = div(ms, 3_600_000)

    cond do
      hours >= 24 ->
        days = div(hours, 24)
        rem_h = rem(hours, 24)
        if rem_h > 0, do: "#{days}d #{rem_h}h", else: "#{days}d"

      hours >= 1 ->
        "#{hours}h"

      true ->
        "< 1h"
    end
  end

  # ---------------------------------------------------------------------------
  # Issue summary
  # ---------------------------------------------------------------------------

  @doc """
  Builds a structured summary map for one issue, combining its current state
  with activity history and inline comments.

  The summary includes:
  - Basic metadata (id, title, state, status, assignees, tags, workstreams)
  - Checklist state (checked/unchecked counts and items)
  - State changes that occurred within `[window_start_ms, window_end_ms]`
  - Comments added within the window
  - Cycle time and net active time (hold/blocked periods excluded)
  - Whether the description was updated within the window

  ## Options

    * `:state_field` – custom field name for state (default: `"State"`)
    * `:assignees_field` – custom field name for assignees (default: `"Assignee"`)
    * `:in_progress_names` – list of state names that mean "in progress" (default: `["In Progress"]`)
    * `:inactive_names` – list of inactive state names (default: `["To Do", "Todo"]`)
    * `:done_names` – list of final state names (default: `["Done", "Won't Do"]`)
    * `:hold_tags` – tags that pause active time (default: `["on hold", "blocked"]`)
    * `:special_tags` – tags to call out in the report (default: `["on hold", "blocked", "to be specified"]`)
    * `:workstreams` – pre-computed list of workstream names for this issue (default: `[]`)
    * `:window_start_ms` – start of the window for filtering changes/comments (default: `nil` = no lower bound)
    * `:window_end_ms` – end of the window (default: current time)
  """
  def build_issue_summary(issue, activities, opts \\ []) do
    state_field = Keyword.get(opts, :state_field, "State")
    assignees_field = Keyword.get(opts, :assignees_field, "Assignee")
    in_progress_names = Keyword.get(opts, :in_progress_names, ["In Progress"])
    inactive_names = Keyword.get(opts, :inactive_names, ["To Do", "Todo"])
    done_names = Keyword.get(opts, :done_names, ["Done", "Won't Do"])
    hold_tags = Keyword.get(opts, :hold_tags, ["on hold", "blocked"])
    special_tags = Keyword.get(opts, :special_tags, ["on hold", "blocked", "to be specified"])
    workstreams = Keyword.get(opts, :workstreams, [])
    window_start_ms = Keyword.get(opts, :window_start_ms)
    window_end_ms = Keyword.get(opts, :window_end_ms, System.system_time(:millisecond))

    tags = Fields.tags(issue)
    state = Fields.state_name(issue, state_field)
    assignees = Fields.assignees(issue, assignees_field)

    tags_lower = MapSet.new(Enum.map(tags, &String.downcase/1))
    special_tags_lower = MapSet.new(Enum.map(special_tags, &String.downcase/1))

    special_tags_present =
      Enum.filter(tags, fn t -> String.downcase(t) in special_tags_lower end)

    is_on_hold =
      Enum.any?(hold_tags, &(String.downcase(&1) in tags_lower))

    start_ms =
      cycle_start_ms(activities, state_field, inactive_names, done_names) || issue["created"]

    end_ms = issue["resolved"] || System.system_time(:millisecond)

    checklist = extract_checklist(issue["description"])

    state_changes_in_window =
      activities
      |> Enum.filter(fn a ->
        get_in(a, ["field", "name"]) == state_field and
          in_window?(a["timestamp"], window_start_ms, window_end_ms)
      end)
      |> Enum.sort_by(& &1["timestamp"])
      |> Enum.map(fn a ->
        %{
          timestamp: a["timestamp"],
          from: extract_names(a["removed"]),
          to: extract_names(a["added"])
        }
      end)

    tag_changes_in_window =
      activities
      |> Enum.filter(fn a ->
        get_in(a, ["field", "name"]) == "tags" and
          in_window?(a["timestamp"], window_start_ms, window_end_ms)
      end)
      |> Enum.sort_by(& &1["timestamp"])
      |> Enum.map(fn a ->
        %{
          timestamp: a["timestamp"],
          added: extract_names(a["added"]),
          removed: extract_names(a["removed"])
        }
      end)

    hold_tag_changes_in_window =
      tag_changes_in_window
      |> Enum.filter(fn tc ->
        hold_lower = MapSet.new(Enum.map(hold_tags, &String.downcase/1))

        Enum.any?(tc.added, &(String.downcase(&1) in hold_lower)) or
          Enum.any?(tc.removed, &(String.downcase(&1) in hold_lower))
      end)

    comments_in_window =
      (issue["comments"] || [])
      |> Enum.filter(fn c ->
        is_integer(c["created"]) and in_window?(c["created"], window_start_ms, window_end_ms)
      end)
      |> Enum.sort_by(& &1["created"])
      |> Enum.map(fn c ->
        author =
          get_in(c, ["author", "name"]) || get_in(c, ["author", "login"]) || "unknown"

        %{author: author, text: c["text"], timestamp: c["created"]}
      end)

    net_active =
      if is_integer(start_ms) and is_integer(end_ms) do
        net_active_time(start_ms, end_ms, activities, hold_tags)
      end

    cycle_time = if is_integer(start_ms), do: end_ms - start_ms, else: nil

    description_updated_in_window =
      is_integer(issue["updated"]) and
        in_window?(issue["updated"], window_start_ms, window_end_ms)

    %{
      id: issue["idReadable"],
      title: issue["summary"],
      state: state,
      status: Status.classify(issue, state, in_progress_names),
      tags: tags,
      special_tags: special_tags_present,
      is_on_hold: is_on_hold,
      assignees: Enum.map(assignees, fn a -> a["name"] || a["login"] end),
      workstreams: workstreams,
      checklist: checklist,
      state_changes_in_window: state_changes_in_window,
      hold_tag_changes_in_window: hold_tag_changes_in_window,
      comments_in_window: comments_in_window,
      cycle_time_ms: cycle_time,
      net_active_time_ms: net_active,
      description_updated_in_window: description_updated_in_window,
      created: issue["created"],
      resolved: issue["resolved"],
      updated: issue["updated"]
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp hold_names(names_list, hold_lower) do
    (names_list || [])
    |> Enum.map(fn item -> item["name"] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&(String.downcase(&1) in hold_lower))
    |> MapSet.new()
  end

  defp extract_names(nil), do: []

  defp extract_names(list) when is_list(list) do
    list |> Enum.map(& &1["name"]) |> Enum.filter(&is_binary/1)
  end

  defp cycle_start_ms(activities, state_field, inactive_names, done_names) do
    inactive_set = inactive_names |> Enum.map(&String.downcase/1) |> MapSet.new()
    done_set = done_names |> Enum.map(&String.downcase/1) |> MapSet.new()

    activities
    |> Enum.filter(fn a -> get_in(a, ["field", "name"]) == state_field end)
    |> Enum.filter(&is_integer(&1["timestamp"]))
    |> Enum.sort_by(& &1["timestamp"])
    |> Enum.find_value(fn a ->
      from_states = extract_names(a["removed"])
      to_states = extract_names(a["added"])

      from_inactive_or_none? =
        from_states == [] or
          Enum.any?(from_states, fn state -> String.downcase(state) in inactive_set end)

      to_active? =
        Enum.any?(to_states, fn state ->
          normalized = String.downcase(state)
          normalized not in inactive_set and normalized not in done_set
        end)

      if from_inactive_or_none? and to_active?, do: a["timestamp"], else: nil
    end)
  end

  defp in_window?(ts, start_ms, end_ms) do
    is_integer(ts) and
      (start_ms == nil or ts >= start_ms) and
      ts <= end_ms
  end
end
