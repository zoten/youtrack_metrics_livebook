defmodule YoutrackWeb.RuntimeConfigReloader do
  @moduledoc false

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
    {"prompts_path", "PROMPTS_PATH", "../prompts"}
  ]

  def reload do
    with :ok <- load_dotenv_files(),
         {:ok, cache_ttl} <- parse_positive_int(System.get_env("YOUTRACK_CACHE_TTL_SECONDS", "600")) do
      dashboard_defaults =
        @dashboard_env_specs
        |> Enum.map(fn {key, env_name, default} -> {key, System.get_env(env_name, default)} end)
        |> Map.new()

      Application.put_env(:youtrack_web, :dashboard_defaults, dashboard_defaults)

      Application.put_env(
        :youtrack_web,
        :report_prompt_files,
        csv_env("YOUTRACK_PROMPT_FILES", "")
      )

      Application.put_env(:youtrack_web, :cache_ttl_seconds, cache_ttl)

      {:ok, dashboard_defaults}
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

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> {:error, "YOUTRACK_CACHE_TTL_SECONDS must be an integer"}
    end
  end
end
