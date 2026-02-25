defmodule Youtrack.StartAt do
  @moduledoc """
  Computes when an issue first entered an "In Progress" state from activity history.
  """

  @doc """
  Finds the earliest timestamp where a state field was changed to one of the given in-progress states.

  Returns the timestamp (integer ms) or `nil` if no matching transition is found.

  ## Examples

      iex> activities = [
      ...>   %{"field" => %{"name" => "State"}, "added" => [%{"name" => "In Progress"}], "timestamp" => 1700000000000},
      ...>   %{"field" => %{"name" => "State"}, "added" => [%{"name" => "Done"}], "timestamp" => 1700100000000}
      ...> ]
      iex> Youtrack.StartAt.from_activities(activities, "State", ["In Progress"])
      1700000000000

      iex> Youtrack.StartAt.from_activities([], "State", ["In Progress"])
      nil
  """
  def from_activities(activities, state_field_name, in_progress_names) do
    activities
    |> Enum.filter(fn a ->
      get_in(a, ["field", "name"]) == state_field_name
    end)
    |> Enum.filter(fn a ->
      added_names =
        (a["added"] || [])
        |> List.wrap()
        |> Enum.map(& &1["name"])
        |> Enum.filter(&is_binary/1)

      Enum.any?(added_names, fn n -> n in in_progress_names end)
    end)
    |> Enum.map(& &1["timestamp"])
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end
end
