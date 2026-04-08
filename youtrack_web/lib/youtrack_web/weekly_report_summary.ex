defmodule YoutrackWeb.WeeklyReportSummary do
  @moduledoc """
  Helper functions for building weekly report summary metrics and rows.
  """

  def summary_metrics(summaries, window_start_ms, window_end_ms) do
    completed_in_window =
      Enum.count(summaries, fn summary ->
        is_integer(summary.resolved) and summary.resolved >= window_start_ms and
          summary.resolved <= window_end_ms
      end)

    hold_count = Enum.count(summaries, & &1.is_on_hold)
    changed_description = Enum.count(summaries, & &1.description_updated_in_window)

    %{
      issues_touched: length(summaries),
      completed_in_window: completed_in_window,
      on_hold: hold_count,
      description_updates: changed_description
    }
  end

  def summary_rows(daily_payload, weekly_payload) do
    [
      %{
        window: "Daily",
        issues: daily_payload.metrics.issues_touched,
        completed: daily_payload.metrics.completed_in_window
      },
      %{
        window: "Weekly",
        issues: weekly_payload.metrics.issues_touched,
        completed: weekly_payload.metrics.completed_in_window
      }
    ]
  end
end