defmodule Youtrack.Fields do
  @moduledoc """
  Helper functions to extract field values from YouTrack issue maps.
  """

  @doc """
  Extracts a custom field value by field name.

  ## Examples

      iex> Youtrack.Fields.custom_field_value(issue, "State")
      %{"name" => "In Progress"}
  """
  def custom_field_value(issue, field_name) do
    (issue["customFields"] || [])
    |> Enum.find(fn f -> f["name"] == field_name end)
    |> case do
      nil -> nil
      f -> f["value"]
    end
  end

  @doc """
  Extracts the state name from an issue.

  ## Examples

      iex> Youtrack.Fields.state_name(issue, "State")
      "In Progress"
  """
  def state_name(issue, state_field) do
    case custom_field_value(issue, state_field) do
      %{"name" => name} -> name
      _ -> nil
    end
  end

  @doc """
  Extracts assignees from an issue, normalized to a list of user maps.

  Handles both single assignee and multiple assignees fields.

  ## Examples

      iex> Youtrack.Fields.assignees(issue, "Assignee")
      [%{"login" => "john", "name" => "John Doe"}]
  """
  def assignees(issue, assignees_field) do
    case custom_field_value(issue, assignees_field) do
      nil ->
        []

      %{"login" => _} = user ->
        [user]

      users when is_list(users) ->
        Enum.filter(users, &is_map/1)

      _ ->
        []
    end
  end

  @doc """
  Extracts the project short name from an issue.

  ## Examples

      iex> Youtrack.Fields.project(issue)
      "MYPROJ"
  """
  def project(issue) do
    get_in(issue, ["project", "shortName"]) || "unknown"
  end

  @doc """
  Extracts tag names from an issue.

  ## Examples

      iex> Youtrack.Fields.tags(issue)
      ["app:finance", "priority:high"]
  """
  def tags(issue) do
    (issue["tags"] || [])
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Extracts the type name from an issue.

  ## Examples

      iex> Youtrack.Fields.type_name(issue)
      "Feature"
  """
  def type_name(issue) do
    case issue["type"] do
      %{"name" => name} when is_binary(name) -> name
      _ -> nil
    end
  end
end
