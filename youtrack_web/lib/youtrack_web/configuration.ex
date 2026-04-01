defmodule YoutrackWeb.Configuration do
  @moduledoc false

  @sections [
    %{
      id: "flow_metrics",
      label: "Flow Metrics",
      stage: "Scaffolding",
      visuals: "21 visualizations",
      description: "Progress, energy, togetherness, autonomy, and PETALS scorecards.",
      highlights: ["Throughput", "Cycle time", "WIP", "Rework", "Rotation"]
    },
    %{
      id: "gantt",
      label: "Gantt",
      stage: "Scaffolding",
      visuals: "7 visualizations",
      description: "Person timelines, interrupt analysis, and live workstream classification.",
      highlights: ["Timeline", "Interrupt mix", "Daily patterns", "Classifier"]
    },
    %{
      id: "pairing",
      label: "Pairing",
      stage: "Scaffolding",
      visuals: "10 visualizations",
      description: "Pair matrices, pairing trends, and firefighter detection.",
      highlights: ["Pair heatmap", "Trend by week", "Firefighters", "Interrupts"]
    },
    %{
      id: "weekly_report",
      label: "Weekly Report",
      stage: "Scaffolding",
      visuals: "Structured payload",
      description: "Signals tables, prompt previews, and local LLM summary generation.",
      highlights: ["JSON payload", "Prompt templates", "Copy/download", "LLM response"]
    }
  ]

  def defaults do
    Application.get_env(:youtrack_web, :dashboard_defaults, %{})
  end

  def sections do
    @sections
  end

  def section(section_id) do
    Enum.find(@sections, hd(@sections), &(&1.id == section_id))
  end
end
