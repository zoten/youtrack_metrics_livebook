defmodule Youtrack.WeeklyReport do
  @moduledoc """
  Builds structured data for weekly and daily digest reports.

  This module provides:
  - Checklist extraction from issue descriptions (markdown `- [ ]` / `- [x]` syntax)
  - Net active time computation, excluding periods when "on hold" or "blocked" tags are active
  - Per-issue structured summaries combining state changes, comments, and checklist state
  - Description change extraction from issue activities with compact before/after excerpts
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
  Computes net active time in milliseconds using the full `[start_ms, end_ms]`
  window and subtracting periods where hold tags were active.

  This compatibility form keeps the previous behavior and does not account for
  state interruptions (for example, returning to `To Do`).

  Returns `nil` when `start_ms` or `end_ms` is nil.
  """
  def net_active_time(start_ms, end_ms, activities, hold_tags)
      when is_integer(start_ms) and is_integer(end_ms) do
    active_intervals = [{start_ms, end_ms}]
    hold_intervals = hold_intervals(activities, hold_tags, start_ms, end_ms)
    active_ms = intervals_total_ms(active_intervals)
    paused_ms = overlap_total_ms(active_intervals, hold_intervals)

    max(0, active_ms - paused_ms)
  end

  def net_active_time(_start_ms, _end_ms, _activities, _hold_tags), do: nil

  @doc """
  Computes net active time in milliseconds with state-awareness:

  1. Build active-state intervals from state transition activities.
  2. Build hold-tag intervals from tag activities.
  3. Subtract only hold overlap that happened while active.

  This excludes interruptions where the issue moves back to inactive/done states.
  Returns `nil` when `start_ms` or `end_ms` is nil.
  """
  def net_active_time(
        start_ms,
        end_ms,
        activities,
        hold_tags,
        state_field,
        inactive_names,
        done_names
      )
      when is_integer(start_ms) and is_integer(end_ms) do
    active_intervals =
      active_intervals(
        activities,
        state_field,
        inactive_names,
        done_names,
        start_ms,
        end_ms
      )

    hold_intervals = hold_intervals(activities, hold_tags, start_ms, end_ms)
    active_ms = intervals_total_ms(active_intervals)
    paused_ms = overlap_total_ms(active_intervals, hold_intervals)

    max(0, active_ms - paused_ms)
  end

  def net_active_time(
        _start_ms,
        _end_ms,
        _activities,
        _hold_tags,
        _state_field,
        _inactive_names,
        _done_names
      ),
      do: nil

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
  - Description changes within the window, plus a derived boolean flag

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

    description_changes_in_window =
      activities
      |> Enum.filter(&description_activity?/1)
      |> Enum.filter(fn activity ->
        in_window?(activity["timestamp"], window_start_ms, window_end_ms)
      end)
      |> Enum.sort_by(& &1["timestamp"])
      |> Enum.map(&normalize_description_change/1)
      |> Enum.reject(&is_nil/1)

    {active_time_intervals, inactive_interruption_intervals} =
      if is_integer(start_ms) and is_integer(end_ms) do
        active =
          active_intervals(
            activities,
            state_field,
            inactive_names,
            done_names,
            start_ms,
            end_ms
          )

        inactive = inverse_intervals(start_ms, end_ms, active)
        {serialize_intervals(active), serialize_intervals(inactive)}
      else
        {[], []}
      end

    net_active =
      if is_integer(start_ms) and is_integer(end_ms) do
        net_active_time(
          start_ms,
          end_ms,
          activities,
          hold_tags,
          state_field,
          inactive_names,
          done_names
        )
      end

    cycle_time = if is_integer(start_ms), do: end_ms - start_ms, else: nil

    description_updated_in_window = description_changes_in_window != []

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
      description_changes_in_window: description_changes_in_window,
      active_time_intervals: active_time_intervals,
      inactive_interruption_intervals: inactive_interruption_intervals,
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
    names_list
    |> extract_names()
    |> Enum.filter(&(String.downcase(&1) in hold_lower))
    |> MapSet.new()
  end

  defp extract_names(nil), do: []

  defp extract_names(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp description_activity?(activity) do
    category_id = get_in(activity, ["category", "id"]) || activity["category"]
    target_member = activity["targetMember"]
    field_name = get_in(activity, ["field", "name"])

    category_id == "DescriptionCategory" or
      normalized_text_key?(target_member, "description") or
      normalized_text_key?(field_name, "description")
  end

  defp normalize_description_change(activity) do
    previous_text = extract_text_value(activity["removed"])
    new_text = extract_text_value(activity["added"])

    if previous_text == new_text do
      nil
    else
      diff = build_text_change(previous_text, new_text)

      %{
        timestamp: activity["timestamp"],
        author: extract_author(activity),
        change_type: diff.change_type,
        previous_text: previous_text,
        new_text: new_text,
        previous_excerpt: diff.previous_excerpt,
        new_excerpt: diff.new_excerpt,
        previous_changed_text: diff.previous_changed_text,
        new_changed_text: diff.new_changed_text
      }
    end
  end

  defp extract_author(activity) do
    get_in(activity, ["author", "name"]) || get_in(activity, ["author", "login"]) || "unknown"
  end

  defp extract_text_value(nil), do: nil

  defp extract_text_value(value) when is_binary(value) do
    value
  end

  defp extract_text_value(value) when is_list(value) do
    value
    |> Enum.map(&extract_text_value/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      [single] -> single
      items -> Enum.join(items, "\n")
    end
  end

  defp extract_text_value(value) when is_map(value) do
    value["text"] || value["value"] || value["name"]
  end

  defp extract_text_value(_value), do: nil

  defp build_text_change(previous_text, new_text) do
    previous = previous_text || ""
    current = new_text || ""
    previous_graphemes = String.graphemes(previous)
    current_graphemes = String.graphemes(current)

    prefix_len = common_prefix_length(previous_graphemes, current_graphemes)

    previous_tail = Enum.drop(previous_graphemes, prefix_len)
    current_tail = Enum.drop(current_graphemes, prefix_len)
    suffix_len = common_suffix_length(previous_tail, current_tail)

    previous_changed_len = max(length(previous_graphemes) - prefix_len - suffix_len, 0)
    current_changed_len = max(length(current_graphemes) - prefix_len - suffix_len, 0)

    %{
      change_type: classify_text_change(previous_text, new_text),
      previous_excerpt:
        excerpt_text(previous_text, previous_graphemes, prefix_len, previous_changed_len),
      new_excerpt: excerpt_text(new_text, current_graphemes, prefix_len, current_changed_len),
      previous_changed_text:
        changed_segment(previous_text, previous_graphemes, prefix_len, previous_changed_len),
      new_changed_text:
        changed_segment(new_text, current_graphemes, prefix_len, current_changed_len)
    }
  end

  defp classify_text_change(previous_text, new_text) do
    cond do
      blank_text?(previous_text) and not blank_text?(new_text) -> "added"
      not blank_text?(previous_text) and blank_text?(new_text) -> "removed"
      true -> "edited"
    end
  end

  defp blank_text?(value), do: value in [nil, ""]

  defp excerpt_text(nil, _graphemes, _prefix_len, _changed_len), do: nil

  defp excerpt_text(_text, graphemes, prefix_len, changed_len) do
    {excerpt_start, excerpt_end} = excerpt_bounds(length(graphemes), prefix_len, changed_len)
    decorate_excerpt(graphemes, excerpt_start, excerpt_end, length(graphemes))
  end

  defp changed_segment(nil, _graphemes, _prefix_len, _changed_len), do: nil

  defp changed_segment(_text, graphemes, prefix_len, changed_len) do
    graphemes
    |> Enum.slice(prefix_len, changed_len)
    |> Enum.join()
  end

  defp excerpt_bounds(total_len, prefix_len, changed_len) do
    context_size = 120
    excerpt_start = max(prefix_len - context_size, 0)
    excerpt_end = min(total_len, prefix_len + changed_len + context_size)
    {excerpt_start, excerpt_end}
  end

  defp decorate_excerpt(graphemes, excerpt_start, excerpt_end, total_len) do
    prefix = if excerpt_start > 0, do: "...", else: ""
    suffix = if excerpt_end < total_len, do: "...", else: ""

    prefix <>
      (graphemes
       |> Enum.slice(excerpt_start, excerpt_end - excerpt_start)
       |> Enum.join()) <> suffix
  end

  defp common_prefix_length(left, right) do
    Enum.zip(left, right)
    |> Enum.take_while(fn {left_item, right_item} -> left_item == right_item end)
    |> length()
  end

  defp common_suffix_length(left, right) do
    Enum.zip(Enum.reverse(left), Enum.reverse(right))
    |> Enum.take_while(fn {left_item, right_item} -> left_item == right_item end)
    |> length()
  end

  defp normalized_text_key?(value, expected) when is_binary(value) do
    String.downcase(value) == String.downcase(expected)
  end

  defp normalized_text_key?(_value, _expected), do: false

  defp hold_intervals(activities, hold_tags, start_ms, end_ms) do
    hold_lower = MapSet.new(Enum.map(hold_tags, &String.downcase/1))

    tag_events =
      activities
      |> Enum.filter(fn a -> get_in(a, ["field", "name"]) == "tags" end)
      |> Enum.filter(&is_integer(&1["timestamp"]))
      |> Enum.sort_by(& &1["timestamp"])

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

    {intervals, in_hold_final, hold_start_final, _holds} =
      tag_events
      |> Enum.filter(fn a -> a["timestamp"] > start_ms and a["timestamp"] <= end_ms end)
      |> Enum.reduce(
        {[], in_hold_at_start, initial_hold_start, active_holds_at_start},
        fn act, {acc, in_hold, hold_start, active_holds} ->
          ts = act["timestamp"]
          added = hold_names(act["added"], hold_lower)
          removed = hold_names(act["removed"], hold_lower)
          next_active_holds = active_holds |> MapSet.union(added) |> MapSet.difference(removed)
          next_in_hold = not Enum.empty?(next_active_holds)

          cond do
            not in_hold and next_in_hold ->
              {acc, true, ts, next_active_holds}

            in_hold and not next_in_hold ->
              {[{hold_start, ts} | acc], false, nil, next_active_holds}

            true ->
              {acc, in_hold, hold_start, next_active_holds}
          end
        end
      )

    intervals =
      if in_hold_final and is_integer(hold_start_final) do
        [{hold_start_final, end_ms} | intervals]
      else
        intervals
      end

    intervals
    |> Enum.reverse()
    |> Enum.filter(fn {s, e} -> is_integer(s) and is_integer(e) and e > s end)
  end

  defp active_intervals(
         activities,
         state_field,
         inactive_names,
         done_names,
         start_ms,
         end_ms
       ) do
    state_events =
      activities
      |> Enum.filter(fn a -> get_in(a, ["field", "name"]) == state_field end)
      |> Enum.filter(&is_integer(&1["timestamp"]))
      |> Enum.sort_by(& &1["timestamp"])

    # By construction, start_ms marks the beginning of cycle-time counting.
    # Treat it as active unless state events explicitly move the issue out.
    {intervals, active, active_start} =
      state_events
      |> Enum.filter(fn a -> a["timestamp"] > start_ms and a["timestamp"] <= end_ms end)
      |> Enum.reduce({[], true, start_ms}, fn act, {acc, active, active_start} ->
        ts = act["timestamp"]
        to_states = extract_names(act["added"])
        removed_states = extract_names(act["removed"])

        to_active? =
          Enum.any?(to_states, fn state ->
            active_state?(state, inactive_names, done_names)
          end)

        to_non_active? =
          to_states != [] and
            Enum.all?(to_states, fn state ->
              not active_state?(state, inactive_names, done_names)
            end)

        removed_active_without_replacement? =
          to_states == [] and
            Enum.any?(removed_states, fn state ->
              active_state?(state, inactive_names, done_names)
            end)

        cond do
          active and (to_non_active? or removed_active_without_replacement?) ->
            {[{active_start, ts} | acc], false, nil}

          not active and to_active? ->
            {acc, true, ts}

          true ->
            {acc, active, active_start}
        end
      end)

    intervals =
      if active and is_integer(active_start) do
        [{active_start, end_ms} | intervals]
      else
        intervals
      end

    intervals
    |> Enum.reverse()
    |> Enum.filter(fn {s, e} -> is_integer(s) and is_integer(e) and e > s end)
  end

  defp active_state?(state, inactive_names, done_names) when is_binary(state) do
    normalized = String.downcase(state)
    inactive_set = inactive_names |> Enum.map(&String.downcase/1) |> MapSet.new()
    done_set = done_names |> Enum.map(&String.downcase/1) |> MapSet.new()

    normalized not in inactive_set and normalized not in done_set
  end

  defp active_state?(_state, _inactive_names, _done_names), do: false

  defp intervals_total_ms(intervals) do
    Enum.reduce(intervals, 0, fn {s, e}, acc -> acc + max(0, e - s) end)
  end

  defp overlap_total_ms(intervals_a, intervals_b) do
    Enum.reduce(intervals_a, 0, fn interval_a, acc ->
      acc +
        Enum.reduce(intervals_b, 0, fn interval_b, acc_b ->
          acc_b + overlap_ms(interval_a, interval_b)
        end)
    end)
  end

  defp overlap_ms({start_a, end_a}, {start_b, end_b}) do
    overlap_start = max(start_a, start_b)
    overlap_end = min(end_a, end_b)
    max(0, overlap_end - overlap_start)
  end

  defp inverse_intervals(start_ms, end_ms, intervals)
       when is_integer(start_ms) and is_integer(end_ms) do
    intervals
    |> Enum.sort_by(fn {s, _e} -> s end)
    |> Enum.reduce({start_ms, []}, fn {s, e}, {cursor, acc} ->
      cond do
        e <= cursor ->
          {cursor, acc}

        s > cursor ->
          {max(cursor, e), [{cursor, s} | acc]}

        true ->
          {max(cursor, e), acc}
      end
    end)
    |> then(fn {cursor, acc} ->
      gaps = if cursor < end_ms, do: [{cursor, end_ms} | acc], else: acc
      gaps |> Enum.reverse() |> Enum.filter(fn {s, e} -> e > s end)
    end)
  end

  defp inverse_intervals(_start_ms, _end_ms, _intervals), do: []

  defp serialize_intervals(intervals) do
    Enum.map(intervals, fn {start_ms, end_ms} ->
      %{start_ms: start_ms, end_ms: end_ms, duration_ms: max(0, end_ms - start_ms)}
    end)
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
