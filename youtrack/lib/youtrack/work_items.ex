defmodule Youtrack.WorkItems do
  @moduledoc """
  Builds work items from YouTrack issues.

  A "work item" explodes each issue into one record per assignee × workstream combination,
  enriching it with status classification, timing, and unplanned work tagging.
  """

  alias Youtrack.{Fields, Status, Workstreams}

  @doc """
  Builds a flat list of work item maps from a list of issues.

  ## Options

    * `:state_field` - Name of the state custom field (e.g. `"State"`)
    * `:assignees_field` - Name of the assignees custom field (e.g. `"Assignee"`)
    * `:rules` - Workstream rules map (from `WorkstreamsLoader`)
    * `:in_progress_names` - List of state names considered "in progress"
    * `:issue_start_at` - Map of `%{issue_id => start_at_ms}` from activity analysis (default: `%{}`)
    * `:excluded_logins` - List of logins to exclude (default: `[]`)
    * `:include_substreams` - Whether to expand to parent workstreams (default: `true`)
    * `:unplanned_tag` - Tag name that marks unplanned/interrupt work (default: `nil`)

  ## Examples

      iex> issues = [%{
      ...>   "id" => "1", "idReadable" => "PROJ-1", "summary" => "[BACKEND] Fix bug",
      ...>   "created" => 1700000000000, "resolved" => 1700100000000,
      ...>   "customFields" => [
      ...>     %{"name" => "State", "value" => %{"name" => "Done"}},
      ...>     %{"name" => "Assignee", "value" => %{"login" => "alice", "name" => "Alice"}}
      ...>   ],
      ...>   "tags" => []
      ...> }]
      iex> rules = %{slug_prefix_to_stream: %{"BACKEND" => ["BACKEND"]}, tag_to_stream: %{}, substream_of: %{}, fallback: ["(unclassified)"]}
      iex> items = Youtrack.WorkItems.build(issues, state_field: "State", assignees_field: "Assignee", rules: rules, in_progress_names: ["In Progress"])
      iex> length(items)
      1
      iex> hd(items).person_login
      "alice"
  """
  def build(issues, opts) do
    state_field = opts[:state_field]
    assignees_field = opts[:assignees_field]
    rules = opts[:rules]
    in_progress_names = opts[:in_progress_names]
    issue_start_at = opts[:issue_start_at] || %{}
    excluded_logins = opts[:excluded_logins] || []
    include_substreams = Keyword.get(opts, :include_substreams, true)
    unplanned_tag = opts[:unplanned_tag]

    issues
    |> Enum.flat_map(fn issue ->
      state_name = Fields.state_name(issue, state_field)
      all_assignees = Fields.assignees(issue, assignees_field)

      assignees =
        Enum.reject(all_assignees, fn a ->
          login = a["login"] || a["name"] || ""
          login in excluded_logins
        end)

      if assignees == [] do
        []
      else
        streams =
          Workstreams.streams_for_issue(issue, rules, include_substreams: include_substreams)

        status = Status.classify(issue, state_name, in_progress_names)

        created = issue["created"]
        resolved = issue["resolved"]
        now_ms = System.system_time(:millisecond)

        start_at = Map.get(issue_start_at, issue["id"]) || created

        end_at =
          cond do
            status == "finished" and is_integer(resolved) -> resolved
            true -> now_ms
          end

        tags = Fields.tags(issue)

        is_unplanned =
          unplanned_tag &&
            Enum.any?(tags, fn t ->
              String.downcase(t) == String.downcase(unplanned_tag)
            end)

        for a <- assignees, stream <- streams do
          %{
            issue_id: issue["idReadable"] || issue["id"],
            issue_internal_id: issue["id"],
            title: issue["summary"],
            person_login: a["login"] || a["name"] || "unknown",
            person_name: a["name"] || a["login"] || "unknown",
            stream: stream,
            state: state_name,
            status: status,
            start_at: start_at,
            end_at: end_at,
            created: created,
            resolved: resolved,
            is_unplanned: is_unplanned,
            tags: tags
          }
        end
      end
    end)
  end
end
