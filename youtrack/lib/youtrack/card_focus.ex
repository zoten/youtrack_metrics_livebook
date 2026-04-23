defmodule Youtrack.CardFocus do
  @moduledoc """
  Builds a card-centric analytics view from one issue and its activity history.
  """

  alias Youtrack.{Fields, Rework, WeeklyReport}

  def build(issue, activities, opts \\ []) do
    state_field = Keyword.get(opts, :state_field, "State")
    assignees_field = Keyword.get(opts, :assignees_field, "Assignee")
    done_names = Keyword.get(opts, :done_names, ["Done", "Won't Do"])
    sprint_field = Keyword.get(opts, :sprint_field, "Sprint")
    workstreams = Keyword.get(opts, :workstreams, [])

    summary =
      WeeklyReport.build_issue_summary(
        issue,
        activities,
        Keyword.merge(opts, window_end_ms: timeline_end_ms(issue))
      )

    state_events = build_state_events(activities, state_field)
    assignee_events = build_assignee_events(activities, assignees_field)
    tag_events = build_tag_events(activities)
    description_events = build_description_events(summary)
    comment_events = build_comment_events(summary)

    rework_events =
      activities
      |> Rework.detect(state_field, done_names)
      |> Enum.map(fn event ->
        Map.merge(event, %{author: author_for_timestamp(state_events, event.timestamp)})
      end)

    time_in_state = build_time_in_state(issue, activities, state_field)

    %{
      issue: %{
        id: issue["idReadable"],
        issue_key: issue["idReadable"],
        internal_id: issue["id"],
        title: issue["summary"],
        state: summary.state,
        status: summary.status,
        project: Fields.project(issue),
        type: Fields.type_name(issue),
        assignees: summary.assignees,
        tags: summary.tags,
        workstreams: workstreams,
        created: issue["created"],
        updated: issue["updated"],
        resolved: issue["resolved"]
      },
      metrics: build_metrics(summary, comment_events, rework_events),
      active_segments: build_active_segments(summary),
      state_segments: build_state_segments(issue, activities, state_field, sprint_field),
      state_events: state_events,
      assignee_events: assignee_events,
      tag_events: tag_events,
      comment_events: comment_events,
      description_events: description_events,
      rework_events: rework_events,
      time_in_state: time_in_state,
      timeline_events:
        build_timeline_events(
          state_events,
          assignee_events,
          tag_events,
          comment_events,
          description_events,
          rework_events
        )
    }
  end

  defp build_metrics(summary, comment_events, rework_events) do
    cycle_time_ms = summary.cycle_time_ms
    net_active_time_ms = summary.net_active_time_ms
    inactive_time_ms = max((cycle_time_ms || 0) - (net_active_time_ms || 0), 0)

    %{
      cycle_time_ms: cycle_time_ms,
      net_active_time_ms: net_active_time_ms,
      inactive_time_ms: inactive_time_ms,
      active_ratio_pct: ratio_pct(net_active_time_ms, cycle_time_ms),
      comment_count: length(comment_events),
      rework_count: length(rework_events)
    }
  end

  defp build_active_segments(summary) do
    total_ms = max(summary.cycle_time_ms || 0, 1)
    hold_intervals = summary.hold_time_intervals

    # Subtract hold intervals from active intervals to create true working segments
    working_intervals =
      summary.active_time_intervals
      |> Enum.flat_map(&subtract_holes(&1, hold_intervals))

    # Clip hold intervals to only the parts overlapping active intervals
    hold_in_active =
      Enum.flat_map(hold_intervals, fn hold ->
        Enum.flat_map(summary.active_time_intervals, fn active ->
          clip_start = max(hold.start_ms, active.start_ms)
          clip_end = min(hold.end_ms, active.end_ms)

          if clip_start < clip_end,
            do: [%{start_ms: clip_start, end_ms: clip_end, duration_ms: clip_end - clip_start}],
            else: []
        end)
      end)

    working = Enum.map(working_intervals, &build_segment(&1, total_ms, "Active", "active"))
    on_hold = Enum.map(hold_in_active, &build_segment(&1, total_ms, "On Hold", "on_hold"))

    inactive =
      Enum.map(summary.inactive_interruption_intervals, fn interval ->
        build_segment(interval, total_ms, "Inactive", "inactive")
      end)

    (working ++ on_hold ++ inactive)
    |> Enum.sort_by(& &1.start_ms)
  end

  defp subtract_holes(interval, holes) do
    sorted_holes =
      holes
      |> Enum.sort_by(& &1.start_ms)

    do_subtract(interval.start_ms, interval.end_ms, sorted_holes)
  end

  defp do_subtract(start_ms, end_ms, _holes) when start_ms >= end_ms, do: []

  defp do_subtract(start_ms, end_ms, []) do
    [%{start_ms: start_ms, end_ms: end_ms, duration_ms: end_ms - start_ms}]
  end

  defp do_subtract(start_ms, end_ms, [hole | rest]) do
    hole_start = max(hole.start_ms, start_ms)
    hole_end = min(hole.end_ms, end_ms)

    cond do
      hole_start >= end_ms ->
        # Hole is entirely past this interval
        [%{start_ms: start_ms, end_ms: end_ms, duration_ms: end_ms - start_ms}]

      hole_end <= start_ms ->
        # Hole is entirely before this interval
        do_subtract(start_ms, end_ms, rest)

      true ->
        before =
          if hole_start > start_ms,
            do: [%{start_ms: start_ms, end_ms: hole_start, duration_ms: hole_start - start_ms}],
            else: []

        before ++ do_subtract(max(hole_end, start_ms), end_ms, rest)
    end
  end

  defp build_segment(interval, total_ms, label, tone) do
    duration_ms = interval.duration_ms

    %{
      start_ms: interval.start_ms,
      end_ms: interval.end_ms,
      duration_ms: duration_ms,
      label: label,
      tone: tone,
      width_pct: Float.round(duration_ms / total_ms * 100, 1)
    }
  end

  defp build_state_segments(issue, activities, state_field, sprint_field) do
    end_ms = timeline_end_ms(issue)
    start_ms = issue["created"] || earliest_timestamp(activities) || end_ms

    state_events =
      activities
      |> Enum.filter(fn activity -> get_in(activity, ["field", "name"]) == state_field end)
      |> Enum.filter(&is_integer(&1["timestamp"]))
      |> Enum.sort_by(& &1["timestamp"])

    sprint_events =
      activities
      |> Enum.filter(fn activity -> get_in(activity, ["field", "name"]) == sprint_field end)
      |> Enum.filter(&is_integer(&1["timestamp"]))
      |> Enum.sort_by(& &1["timestamp"])

    initial_state = infer_initial_state(issue, state_field, state_events)
    initial_sprint = infer_initial_sprint(issue, sprint_field, sprint_events)

    change_points =
      (Enum.map(state_events, & &1["timestamp"]) ++ Enum.map(sprint_events, & &1["timestamp"]))
      |> Enum.filter(fn timestamp ->
        is_integer(timestamp) and timestamp > start_ms and timestamp <= end_ms
      end)
      |> Enum.uniq()
      |> Enum.sort()

    state_events_by_timestamp = Enum.group_by(state_events, & &1["timestamp"])
    sprint_events_by_timestamp = Enum.group_by(sprint_events, & &1["timestamp"])

    segments =
      change_points
      |> Enum.reduce({start_ms, initial_state, initial_sprint, []}, fn timestamp,
                                                                       {cursor, current_state,
                                                                        current_sprint, acc} ->
        segment = build_state_segment(cursor, timestamp, current_state, current_sprint)

        next_state =
          state_events_by_timestamp
          |> Map.get(timestamp, [])
          |> Enum.reduce(current_state, fn activity, state ->
            List.first(extract_names(activity["added"])) || state
          end)

        next_sprint =
          sprint_events_by_timestamp
          |> Map.get(timestamp, [])
          |> Enum.reduce(current_sprint, fn activity, sprint_names ->
            added = extract_names(activity["added"])
            removed = extract_names(activity["removed"])

            cond do
              added != [] -> added
              removed != [] -> []
              true -> sprint_names
            end
          end)

        {timestamp, next_state, next_sprint, [segment | acc]}
      end)
      |> then(fn {cursor, current_state, current_sprint, acc} ->
        final_segment = build_state_segment(cursor, end_ms, current_state, current_sprint)

        [final_segment | acc]
      end)

    segments
    |> Enum.reverse()
    |> Enum.filter(fn seg -> seg.duration_ms > 0 and is_binary(seg.state) and seg.state != "" end)
  end

  defp build_state_segment(start_ms, end_ms, state, sprint_names) do
    sprint_names = Enum.uniq(List.wrap(sprint_names))

    %{
      start_ms: start_ms,
      end_ms: end_ms,
      state: state,
      duration_ms: end_ms - start_ms,
      has_sprint?: sprint_names != [],
      sprint_names: sprint_names
    }
  end

  defp infer_initial_sprint(issue, sprint_field, [first_event | _rest]) do
    removed = extract_names(first_event["removed"])

    if removed != [] do
      removed
    else
      custom_field_names(issue, sprint_field)
    end
  end

  defp infer_initial_sprint(issue, sprint_field, []) do
    custom_field_names(issue, sprint_field)
  end

  defp custom_field_names(issue, field_name) do
    issue
    |> Map.get("customFields", [])
    |> Enum.find(fn field -> field["name"] == field_name end)
    |> case do
      nil -> []
      field -> extract_names(field["value"])
    end
  end

  defp build_state_events(activities, state_field) do
    activities
    |> Enum.filter(fn activity -> get_in(activity, ["field", "name"]) == state_field end)
    |> Enum.filter(&is_integer(&1["timestamp"]))
    |> Enum.sort_by(& &1["timestamp"], :desc)
    |> Enum.map(fn activity ->
      %{
        timestamp: activity["timestamp"],
        author: extract_author(activity),
        from: extract_names(activity["removed"]),
        to: extract_names(activity["added"]),
        type: "state_changed"
      }
    end)
  end

  defp build_assignee_events(activities, assignees_field) do
    activities
    |> Enum.filter(fn activity -> get_in(activity, ["field", "name"]) == assignees_field end)
    |> Enum.filter(&is_integer(&1["timestamp"]))
    |> Enum.sort_by(& &1["timestamp"], :desc)
    |> Enum.map(fn activity ->
      %{
        timestamp: activity["timestamp"],
        author: extract_author(activity),
        from: extract_names(activity["removed"]),
        to: extract_names(activity["added"]),
        type: "assignee_changed"
      }
    end)
  end

  defp build_tag_events(activities) do
    activities
    |> Enum.filter(fn activity ->
      get_in(activity, ["field", "name"]) == "tags" or
        get_in(activity, ["category", "id"]) == "TagsCategory"
    end)
    |> Enum.filter(&is_integer(&1["timestamp"]))
    |> Enum.sort_by(& &1["timestamp"], :desc)
    |> Enum.map(fn activity ->
      %{
        timestamp: activity["timestamp"],
        author: extract_author(activity),
        added: extract_names(activity["added"]),
        removed: extract_names(activity["removed"]),
        type: "tags_changed"
      }
    end)
  end

  defp build_description_events(summary) do
    summary.description_changes_in_window
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.map(fn event ->
      %{
        timestamp: event.timestamp,
        author: event.author,
        change_type: event.change_type,
        previous_excerpt: event.previous_excerpt,
        new_excerpt: event.new_excerpt,
        type: "description_changed"
      }
    end)
  end

  defp build_comment_events(summary) do
    summary.comments_in_window
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.map(fn event ->
      %{
        timestamp: event.timestamp,
        author: event.author,
        text: event.text,
        type: "comment_added"
      }
    end)
  end

  defp build_timeline_events(
         state_events,
         assignee_events,
         tag_events,
         comment_events,
         description_events,
         rework_events
       ) do
    (state_events ++
       assignee_events ++ tag_events ++ comment_events ++ description_events ++ rework_events)
    |> Enum.sort_by(& &1.timestamp, :desc)
  end

  defp build_time_in_state(issue, activities, state_field) do
    end_ms = timeline_end_ms(issue)
    start_ms = issue["created"] || earliest_timestamp(activities) || end_ms

    state_events =
      activities
      |> Enum.filter(fn activity -> get_in(activity, ["field", "name"]) == state_field end)
      |> Enum.filter(&is_integer(&1["timestamp"]))
      |> Enum.sort_by(& &1["timestamp"])

    initial_state = infer_initial_state(issue, state_field, state_events)

    segments =
      state_events
      |> Enum.reduce({start_ms, initial_state, []}, fn activity, {cursor, current_state, acc} ->
        timestamp = activity["timestamp"]
        next_state = List.first(extract_names(activity["added"])) || current_state

        acc =
          if is_binary(current_state) and is_integer(cursor) and timestamp > cursor do
            [
              %{
                state: current_state,
                start_ms: cursor,
                end_ms: timestamp,
                duration_ms: timestamp - cursor
              }
              | acc
            ]
          else
            acc
          end

        {timestamp, next_state, acc}
      end)
      |> then(fn {cursor, current_state, acc} ->
        if is_binary(current_state) and is_integer(cursor) and end_ms > cursor do
          [
            %{
              state: current_state,
              start_ms: cursor,
              end_ms: end_ms,
              duration_ms: end_ms - cursor
            }
            | acc
          ]
        else
          acc
        end
      end)

    segments
    |> Enum.group_by(& &1.state)
    |> Enum.map(fn {state, state_segments} ->
      duration_ms =
        Enum.reduce(state_segments, 0, fn segment, total -> total + segment.duration_ms end)

      %{state: state, duration_ms: duration_ms}
    end)
    |> Enum.sort_by(& &1.duration_ms, :desc)
  end

  defp infer_initial_state(issue, state_field, [first_event | _rest]) do
    List.first(extract_names(first_event["removed"])) ||
      List.first(extract_names(first_event["added"])) ||
      Fields.state_name(issue, state_field)
  end

  defp infer_initial_state(issue, state_field, []) do
    Fields.state_name(issue, state_field)
  end

  defp extract_author(activity) do
    get_in(activity, ["author", "name"]) || get_in(activity, ["author", "login"]) || "unknown"
  end

  defp extract_names(nil), do: []

  defp extract_names(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      %{"login" => login} when is_binary(login) -> [login]
      %{"text" => text} when is_binary(text) -> [text]
      value when is_binary(value) -> [value]
      _ -> []
    end)
  end

  defp earliest_timestamp(activities) do
    activities
    |> Enum.filter(&is_integer(&1["timestamp"]))
    |> Enum.min_by(& &1["timestamp"], fn -> nil end)
    |> case do
      nil -> nil
      activity -> activity["timestamp"]
    end
  end

  defp timeline_end_ms(issue) do
    issue["resolved"] || System.system_time(:millisecond)
  end

  defp ratio_pct(_part, nil), do: nil
  defp ratio_pct(nil, _whole), do: nil
  defp ratio_pct(_part, 0), do: nil
  defp ratio_pct(part, whole), do: Float.round(part / whole * 100, 1)

  defp author_for_timestamp(state_events, timestamp) do
    state_events
    |> Enum.find(fn event -> event.timestamp == timestamp end)
    |> case do
      nil -> "unknown"
      event -> event.author
    end
  end
end
