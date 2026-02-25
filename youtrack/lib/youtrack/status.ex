defmodule Youtrack.Status do
  @moduledoc """
  Classifies issue status based on its resolved timestamp and current state.
  """

  @doc """
  Classifies an issue as `"finished"`, `"ongoing"`, or `"unfinished"`.

  - `"finished"` — issue has a non-nil `"resolved"` timestamp
  - `"ongoing"` — issue is in one of the `in_progress_names` states
  - `"unfinished"` — everything else

  ## Examples

      iex> Youtrack.Status.classify(%{"resolved" => 1700000000000}, "In Progress", ["In Progress"])
      "finished"

      iex> Youtrack.Status.classify(%{"resolved" => nil}, "In Progress", ["In Progress"])
      "ongoing"

      iex> Youtrack.Status.classify(%{"resolved" => nil}, "Open", ["In Progress"])
      "unfinished"
  """
  def classify(issue, state_name, in_progress_names) do
    resolved = issue["resolved"]

    cond do
      not is_nil(resolved) -> "finished"
      state_name in in_progress_names -> "ongoing"
      true -> "unfinished"
    end
  end
end
