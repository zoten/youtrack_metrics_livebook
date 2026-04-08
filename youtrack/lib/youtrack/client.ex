defmodule Youtrack.Client do
  @moduledoc """
  YouTrack API client.

  Creates authenticated Req clients and provides functions to fetch issues and activities.
  """

  @default_activity_fields [
    "id",
    "timestamp",
    "category(id)",
    "author(name,login)",
    "field(name)",
    "targetMember",
    "added(name)",
    "removed(name)",
    "markup"
  ]

  @default_activity_categories "CustomFieldCategory,TagsCategory"

  @default_fields [
    "idReadable",
    "id",
    "summary",
    "created",
    "updated",
    "resolved",
    "project(shortName)",
    "type(name)",
    "tags(name)",
    "customFields(name,value(name,login))"
  ]

  @doc """
  Creates a new authenticated Req client for YouTrack API.

  ## Examples

      iex> client = Youtrack.Client.new!("https://example.youtrack.cloud", "your-token")
      %Req.Request{...}
  """
  def new!(base_url, token) when is_binary(base_url) and is_binary(token) do
    base_url = String.trim_trailing(base_url, "/")

    Req.new(
      base_url: base_url,
      headers: [
        {"accept", "application/json"},
        {"authorization", "Bearer " <> token}
      ]
    )
  end

  @doc """
  Fetches issues from YouTrack with pagination.

  ## Options

    * `:fields` - List of fields to fetch (default: standard fields including customFields)
    * `:top` - Number of issues per page (default: 100)

  ## Examples

      iex> issues = Youtrack.Client.fetch_issues!(client, "project: MYPROJ")
      [%{"id" => "...", "summary" => "..."}, ...]
  """
  def fetch_issues!(req, query, opts \\ []) do
    fields = Keyword.get(opts, :fields, @default_fields)
    top = Keyword.get(opts, :top, 100)

    fields_str = if is_list(fields), do: Enum.join(fields, ","), else: fields

    Stream.unfold(0, fn
      nil ->
        nil

      skip ->
        params = %{
          "query" => query,
          "fields" => fields_str,
          "$top" => top,
          "$skip" => skip
        }

        resp = Req.get!(req, url: "/api/issues", params: params)

        if resp.status != 200 do
          raise "YouTrack API returned status #{resp.status}: #{inspect(resp.body) |> String.slice(0, 300)}"
        end

        items = resp.body

        cond do
          not is_list(items) ->
            raise "Expected list of issues, got: #{inspect(items) |> String.slice(0, 200)}"

          items == [] ->
            nil

          length(items) < top ->
            {items, nil}

          true ->
            {items, skip + top}
        end
    end)
    |> Enum.to_list()
    |> List.flatten()
  end

  @doc """
  Fetches activities for a specific issue.

  Used to compute precise timestamps like when an issue transitioned to "In Progress".

  ## Options

    * `:fields` - Activity fields to fetch
    * `:categories` - Activity categories filter (default: custom fields and tags)
    * `:top` - Number of activities per page (default: 100)
    * `:start` - Optional inclusive lower timestamp bound in milliseconds
    * `:end` - Optional inclusive upper timestamp bound in milliseconds
    * `:reverse` - Whether to fetch newest-first (default: false)
  """
  def fetch_activities!(req, issue_id, opts \\ []) do
    fields = Keyword.get(opts, :fields, @default_activity_fields)
    categories = Keyword.get(opts, :categories, @default_activity_categories)
    top = Keyword.get(opts, :top, 100)
    start_ms = Keyword.get(opts, :start)
    end_ms = Keyword.get(opts, :end)
    reverse = Keyword.get(opts, :reverse, false)

    fields_str = if is_list(fields), do: Enum.join(fields, ","), else: fields

    Stream.unfold(0, fn
      nil ->
        nil

      skip ->
        params =
          %{
            "categories" => categories,
            "fields" => fields_str,
            "$top" => top,
            "$skip" => skip,
            "reverse" => reverse
          }
          |> maybe_put_param("start", start_ms)
          |> maybe_put_param("end", end_ms)

        resp = Req.get!(req, url: "/api/issues/#{issue_id}/activities", params: params)

        if resp.status != 200 do
          raise "YouTrack API returned status #{resp.status} for activities: #{inspect(resp.body) |> String.slice(0, 300)}"
        end

        items = resp.body

        cond do
          not is_list(items) ->
            raise "Expected list of activities, got: #{inspect(items) |> String.slice(0, 200)}"

          items == [] ->
            nil

          length(items) < top ->
            {items, nil}

          true ->
            {items, skip + top}
        end
    end)
    |> Enum.to_list()
    |> List.flatten()
  end

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)
end
