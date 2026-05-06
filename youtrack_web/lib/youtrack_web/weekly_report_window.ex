defmodule YoutrackWeb.WeeklyReportWindow do
  @moduledoc false

  def issue_fetch_end(week_end, last_working_day) do
    case Date.compare(week_end, last_working_day) do
      :lt -> last_working_day
      _ -> week_end
    end
  end
end