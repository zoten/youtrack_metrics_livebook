defmodule YoutrackWeb.WeeklyReportSummaryTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.WeeklyReportSummary

  test "summary_metrics/3 counts completed, hold, and description updates" do
    summaries = [
      %{resolved: 1_700, is_on_hold: false, description_updated_in_window: true},
      %{resolved: 900, is_on_hold: true, description_updated_in_window: false},
      %{resolved: nil, is_on_hold: true, description_updated_in_window: true}
    ]

    metrics = WeeklyReportSummary.summary_metrics(summaries, 1_000, 2_000)

    assert metrics == %{
             issues_touched: 3,
             completed_in_window: 1,
             on_hold: 2,
             description_updates: 2
           }
  end

  test "summary_rows/2 maps payload metrics to daily and weekly rows" do
    daily_payload = %{metrics: %{issues_touched: 2, completed_in_window: 1}}
    weekly_payload = %{metrics: %{issues_touched: 7, completed_in_window: 4}}

    assert WeeklyReportSummary.summary_rows(daily_payload, weekly_payload) == [
             %{window: "Daily", issues: 2, completed: 1},
             %{window: "Weekly", issues: 7, completed: 4}
           ]
  end
end