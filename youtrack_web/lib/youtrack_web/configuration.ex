defmodule YoutrackWeb.Configuration do
  @moduledoc false

  alias YoutrackWeb.RuntimeConfig

  @sections [
    %{
      id: "flow_metrics",
      label: "Flow Metrics",
      stage: "Ready",
      visuals: "21 visualizations",
      description: "Progress, energy, togetherness, autonomy, and PETALS scorecards.",
      highlights: ["Throughput", "Cycle time", "WIP", "Rework", "Rotation"]
    },
    %{
      id: "gantt",
      label: "Gantt",
      stage: "Ready",
      visuals: "7 visualizations",
      description: "Person timelines, interrupt analysis, and live workstream classification.",
      highlights: ["Timeline", "Interrupt mix", "Daily patterns", "Classifier"]
    },
    %{
      id: "pairing",
      label: "Pairing",
      stage: "Ready",
      visuals: "10 visualizations",
      description: "Pair matrices, pairing trends, and firefighter detection.",
      highlights: ["Pair heatmap", "Trend by week", "Firefighters", "Interrupts"]
    },
    %{
      id: "weekly_report",
      label: "Weekly Report",
      stage: "Ready",
      visuals: "Structured payload",
      description: "Signals tables, prompt previews, and local LLM summary generation.",
      highlights: ["JSON payload", "Prompt templates", "Copy/download", "LLM response"]
    },
    %{
      id: "card_focus",
      label: "Card Focus",
      stage: "In progress",
      visuals: "Issue deep-dive",
      description:
        "Inspect one card with a dedicated timeline, history events, and delivery signals.",
      highlights: ["State timeline", "Cycle vs net active", "Comments", "Tags"]
    },
    %{
      id: "workstream_config",
      label: "Workstream Config",
      stage: "Ready",
      visuals: "Configuration",
      description: "Edit workstream rules, classify untracked slugs, review match coverage.",
      highlights: ["YAML editor", "Slug classifier", "Match coverage", "Auto-save"]
    },
    %{
      id: "comparison",
      label: "Card Comparison",
      stage: "In progress",
      visuals: "Side-by-side timelines",
      description:
        "Compare 2-4 issues side by side with aligned Gantt charts and shared event timelines.",
      highlights: ["Shared Gantt", "Event timelines", "Metric comparison", "Side-by-side"]
    },
    %{
      id: "workstream_analyzer",
      label: "Workstream Analyzer",
      stage: "In progress",
      visuals: "Effort over time",
      description:
        "Compare streams in one trend chart or inspect how substreams compose a parent stream.",
      highlights: ["Effort normalization", "Compare mode", "Composition mode", "Diagnostics"]
    }
  ]

  @shared_fields [
    "base_url",
    "token",
    "base_query",
    "days_back",
    "state_field",
    "assignees_field",
    "in_progress_names",
    "done_state_names",
    "project_prefix",
    "excluded_logins",
    "use_activities",
    "include_substreams",
    "unplanned_tag",
    "workstreams_path",
    "effort_mappings_path",
    "prompts_path"
  ]

  def defaults do
    RuntimeConfig.dashboard_defaults()
  end

  def shared_fields do
    @shared_fields
  end

  def shared_defaults(config) when is_map(config) do
    Map.take(config, @shared_fields)
  end

  def merge_shared(config, incoming) when is_map(config) and is_map(incoming) do
    shared_incoming =
      incoming
      |> Map.take(@shared_fields)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {key, normalize_value(value)} end)

    Map.merge(config, shared_incoming)
  end

  def merge_partial(config, incoming) when is_map(config) and is_map(incoming) do
    normalized =
      incoming
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {key, normalize_value(value)} end)

    Map.merge(config, normalized)
  end

  def shared_from_socket(socket) do
    socket
    |> maybe_connect_params()
    |> Map.get("shared_config")
    |> normalize_shared_payload()
  end

  def reload_defaults do
    case RuntimeConfig.reload() do
      {:ok, snapshot} -> {:ok, snapshot.dashboard_defaults}
      {:error, reason} -> {:error, reason}
    end
  end

  def sections do
    @sections
  end

  defp maybe_connect_params(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.LiveView.get_connect_params(socket) || %{}
    else
      %{}
    end
  end

  defp normalize_shared_payload(payload) when is_map(payload), do: payload
  defp normalize_shared_payload(_), do: %{}

  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(value) when is_boolean(value), do: to_string(value)
  defp normalize_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_value(value) when is_float(value), do: Float.to_string(value)
  defp normalize_value(value), do: value
end
