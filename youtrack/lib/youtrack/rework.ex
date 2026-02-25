defmodule Youtrack.Rework do
  @moduledoc """
  Detects rework events from YouTrack activity history.

  A rework event occurs when an issue transitions out of a "done" state
  back into an active state, indicating the work was reopened.
  """

  @doc """
  Detects rework events from an issue's activity history.

  Returns a list of rework event maps, each with `:timestamp`, `:from`, and `:to` keys.
  A rework event is any state transition where the removed state is in `done_state_names`.

  ## Examples

      iex> activities = [
      ...>   %{"field" => %{"name" => "State"}, "added" => [%{"name" => "Done"}], "removed" => [%{"name" => "In Progress"}], "timestamp" => 1000},
      ...>   %{"field" => %{"name" => "State"}, "added" => [%{"name" => "In Progress"}], "removed" => [%{"name" => "Done"}], "timestamp" => 2000}
      ...> ]
      iex> Youtrack.Rework.detect(activities, "State", ["Done"])
      [%{timestamp: 2000, from: ["Done"], to: ["In Progress"]}]
  """
  def detect(activities, state_field_name, done_state_names) do
    activities
    |> Enum.filter(fn a ->
      get_in(a, ["field", "name"]) == state_field_name
    end)
    |> Enum.sort_by(& &1["timestamp"])
    |> Enum.filter(fn a ->
      removed_names = extract_state_names(a["removed"])
      Enum.any?(removed_names, &(&1 in done_state_names))
    end)
    |> Enum.map(fn a ->
      %{
        timestamp: a["timestamp"],
        from: extract_state_names(a["removed"]),
        to: extract_state_names(a["added"])
      }
    end)
  end

  @doc """
  Counts rework events for a batch of issues.

  Takes a map of `%{issue_id => activities}` and returns `%{issue_id => rework_count}`,
  only including issues with at least one rework event.
  """
  def count_by_issue(issue_activities_map, state_field_name, done_state_names) do
    issue_activities_map
    |> Enum.map(fn {issue_id, activities} ->
      events = detect(activities, state_field_name, done_state_names)
      {issue_id, length(events)}
    end)
    |> Enum.filter(fn {_id, count} -> count > 0 end)
    |> Map.new()
  end

  defp extract_state_names(values) do
    (values || [])
    |> List.wrap()
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
  end
end
