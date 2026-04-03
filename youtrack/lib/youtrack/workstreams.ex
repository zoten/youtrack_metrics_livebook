defmodule Youtrack.Workstreams do
  @moduledoc """
  Matches issues to workstreams based on summary slugs and tags.
  """

  @doc """
  Parses rules from an Elixir map literal string.

  Normalizes slug keys to uppercase and collapses whitespace.
  Used when rules are edited in a Livebook textarea.
  """
  def parse_rules!(text) do
    {rules, _binding} = Code.eval_string(text)

    normalized_slug_map =
      rules.slug_prefix_to_stream
      |> Enum.map(fn {k, v} -> {normalize_slug(k), v} end)
      |> Enum.into(%{})

    normalized_tag_map =
      rules.tag_to_stream
      |> Enum.map(fn {k, v} -> {String.upcase(k), v} end)
      |> Enum.into(%{})

    normalized_type_map =
      Map.get(rules, :type_to_stream, %{})
      |> Enum.map(fn {k, v} -> {normalize_slug(k), v} end)
      |> Enum.into(%{})

    substream_map = Map.get(rules, :substream_of, %{})

    Map.merge(rules, %{
      slug_prefix_to_stream: normalized_slug_map,
      tag_to_stream: normalized_tag_map,
      type_to_stream: normalized_type_map,
      substream_of: substream_map
    })
  end

  @doc """
  Extracts the slug from an issue summary (e.g., "[BACKEND] Fix bug" -> "BACKEND").

  ## Examples

      iex> Youtrack.Workstreams.summary_slug("[BACKEND] Fix the bug")
      "BACKEND"

      iex> Youtrack.Workstreams.summary_slug("No slug here")
      nil
  """
  def summary_slug(nil), do: nil

  def summary_slug(summary) when is_binary(summary) do
    case Regex.run(~r/^\s*\[([^\]]+)\]/, summary) do
      [_, slug] -> String.trim(slug)
      _ -> nil
    end
  end

  @doc """
  Canonicalizes a slug for grouping: trims, collapses spaces, uppercases.
  Returns "(no slug)" for nil input.

  ## Examples

      iex> Youtrack.Workstreams.canonical_slug("  backend  ")
      "BACKEND"

      iex> Youtrack.Workstreams.canonical_slug(nil)
      "(no slug)"
  """
  def canonical_slug(nil), do: "(no slug)"

  def canonical_slug(slug) do
    slug
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/\s+/, " ")
  end

  @doc """
  Normalizes a slug: trims, collapses spaces, uppercases.
  Returns nil for nil input.

  ## Examples

      iex> Youtrack.Workstreams.normalize_slug("  rest api  ")
      "REST API"

      iex> Youtrack.Workstreams.normalize_slug(nil)
      nil
  """
  def normalize_slug(nil), do: nil

  def normalize_slug(slug) when is_binary(slug) do
    slug
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.upcase()
  end

  @doc """
  Extracts tag names from an issue and filters to strings only.
  """
  def issue_tags(issue) do
    (issue["tags"] || [])
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Determines which workstreams an issue belongs to based on rules.

  ## Options

    * `:include_substreams` - When true (default), also includes parent workstreams

  ## Examples

      iex> rules = %{
      ...>   slug_prefix_to_stream: %{"BACKEND" => ["BACKEND"]},
      ...>   tag_to_stream: %{},
      ...>   type_to_stream: %{},
      ...>   substream_of: %{},
      ...>   fallback: ["(unclassified)"]
      ...> }
      iex> issue = %{"summary" => "[BACKEND] Fix bug", "tags" => []}
      iex> Youtrack.Workstreams.streams_for_issue(issue, rules)
      ["BACKEND"]
  """
  def streams_for_issue(issue, rules, opts \\ []) do
    include_substreams = Keyword.get(opts, :include_substreams, true)

    raw_slug = issue["summary"] |> summary_slug()
    slug = normalize_slug(raw_slug)

    tags =
      issue_tags(issue)
      |> Enum.map(&String.upcase/1)

    issue_type =
      case issue["type"] do
        %{"name" => name} when is_binary(name) -> name
        _ -> nil
      end

    from_slug =
      case slug do
        nil -> []
        s -> Map.get(rules.slug_prefix_to_stream, s, [])
      end

    from_tags =
      tags
      |> Enum.flat_map(fn t -> Map.get(rules.tag_to_stream, t, []) end)

    from_type =
      case issue_type do
        nil -> []
        t -> Map.get(rules.type_to_stream, t, [])
      end

    base_streams = (from_slug ++ from_tags ++ from_type) |> Enum.uniq()

    streams =
      if include_substreams do
        expand_to_parents(base_streams, rules)
      else
        base_streams
      end

    if streams == [] do
      rules.fallback || ["(unclassified)"]
    else
      streams
    end
  end

  @doc """
  Expands a list of workstreams to include their parent workstreams.
  """
  def expand_to_parents(streams, rules) do
    substream_map = Map.get(rules, :substream_of, %{})

    Enum.flat_map(streams, fn stream ->
      parents = Map.get(substream_map, stream, [])
      [stream | parents]
    end)
    |> Enum.uniq()
  end
end
