defmodule YoutrackWeb.RuntimeConfigReloader do
  @moduledoc false

  alias YoutrackWeb.EffortMappingsLoader
  alias Youtrack.WorkstreamsLoader

  @dotenv_paths [
    Path.expand("../../../.env", __DIR__),
    Path.expand("../../.env", __DIR__)
  ]

  @dashboard_env_specs [
    {"base_url", "YOUTRACK_BASE_URL", "https://your-instance.youtrack.cloud"},
    {"token", "YOUTRACK_TOKEN", ""},
    {"base_query", "YOUTRACK_BASE_QUERY", "project: MYPROJECT"},
    {"days_back", "YOUTRACK_DAYS_BACK", "90"},
    {"state_field", "YOUTRACK_STATE_FIELD", "State"},
    {"assignees_field", "YOUTRACK_ASSIGNEES_FIELD", "Assignee"},
    {"in_progress_names", "YOUTRACK_IN_PROGRESS", "In Progress"},
    {"done_state_names", "YOUTRACK_DONE_STATES", "Done, Verified, Fixed"},
    {"project_prefix", "YOUTRACK_PROJECT_PREFIX", ""},
    {"excluded_logins", "YOUTRACK_EXCLUDED_LOGINS", ""},
    {"use_activities", "YOUTRACK_USE_ACTIVITIES", "true"},
    {"include_substreams", "YOUTRACK_INCLUDE_SUBSTREAMS", "true"},
    {"unplanned_tag", "YOUTRACK_UNPLANNED_TAG", "on the ankles"},
    {"workstreams_path", "WORKSTREAMS_PATH", "../workstreams.yaml"},
    {"effort_mappings_path", "EFFORT_MAPPINGS_PATH", "../effort_mappings.yaml"},
    {"prompts_path", "PROMPTS_PATH", "../prompts"}
  ]

  def dotenv_paths, do: @dotenv_paths

  def load_snapshot do
    with :ok <- load_dotenv_files(),
         {:ok, cache_ttl} <-
           parse_positive_int(System.get_env("YOUTRACK_CACHE_TTL_SECONDS", "600")) do
      dashboard_defaults =
        @dashboard_env_specs
        |> Enum.map(fn {key, env_name, default} -> {key, System.get_env(env_name, default)} end)
        |> Map.new()

      {workstream_rules, workstreams_path} =
        load_workstream_rules(Map.get(dashboard_defaults, "workstreams_path", ""))

      {effort_mappings, effort_mappings_path} =
        load_effort_mappings(Map.get(dashboard_defaults, "effort_mappings_path", ""))

      {:ok,
       %{
         dashboard_defaults: dashboard_defaults,
         cache_ttl_seconds: cache_ttl,
         report_prompt_files: csv_env("YOUTRACK_PROMPT_FILES", ""),
         workstream_rules: workstream_rules,
         workstreams_path: workstreams_path,
         effort_mappings: effort_mappings,
         effort_mappings_path: effort_mappings_path
       }}
    end
  end

  def reload do
    case load_snapshot() do
      {:ok, snapshot} -> {:ok, snapshot.dashboard_defaults}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_dotenv_files do
    Enum.reduce_while(@dotenv_paths, :ok, fn path, _acc ->
      if File.exists?(path) do
        case File.read(path) do
          {:ok, content} ->
            content
            |> String.split("\n")
            |> Enum.each(fn line ->
              case parse_env_line(line) do
                {key, value} -> System.put_env(key, value)
                :skip -> :ok
              end
            end)

            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, "failed to read #{path}: #{inspect(reason)}"}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp parse_env_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :skip

      String.starts_with?(trimmed, "#") ->
        :skip

      true ->
        normalized =
          if String.starts_with?(trimmed, "export ") do
            String.trim_leading(trimmed, "export ")
          else
            trimmed
          end

        case String.split(normalized, "=", parts: 2) do
          [key, value] ->
            env_key = String.trim(key)

            env_value =
              value
              |> String.trim()
              |> String.trim_leading("\"")
              |> String.trim_trailing("\"")
              |> String.trim_leading("'")
              |> String.trim_trailing("'")

            if env_key == "" do
              :skip
            else
              {env_key, env_value}
            end

          _ ->
            :skip
        end
    end
  end

  defp csv_env(name, default) do
    name
    |> System.get_env(default)
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp load_workstream_rules("") do
    WorkstreamsLoader.load_from_default_paths()
  end

  defp load_workstream_rules(path) do
    case WorkstreamsLoader.load_file(path) do
      {:ok, rules} -> {rules, path}
      {:error, _reason} -> {WorkstreamsLoader.empty_rules(), path}
    end
  end

  defp load_effort_mappings("") do
    EffortMappingsLoader.load_from_default_paths()
  end

  defp load_effort_mappings(path) do
    case EffortMappingsLoader.load_file(path) do
      {:ok, mappings} -> {mappings, path}
      {:error, _reason} -> {EffortMappingsLoader.empty_mappings(), path}
    end
  end

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> {:error, "YOUTRACK_CACHE_TTL_SECONDS must be an integer"}
    end
  end
end
