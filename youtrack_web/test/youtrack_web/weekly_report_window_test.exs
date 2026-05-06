defmodule YoutrackWeb.WeeklyReportWindowTest do
  use ExUnit.Case, async: true

  alias YoutrackWeb.WeeklyReportWindow

  test "uses last working day when it extends beyond the configured week end" do
    week_end = ~D[2026-05-01]
    last_working_day = ~D[2026-05-04]

    assert WeeklyReportWindow.issue_fetch_end(week_end, last_working_day) == last_working_day
  end

  test "keeps week end when it already covers the last working day" do
    week_end = ~D[2026-05-09]
    last_working_day = ~D[2026-05-08]

    assert WeeklyReportWindow.issue_fetch_end(week_end, last_working_day) == week_end
  end
end