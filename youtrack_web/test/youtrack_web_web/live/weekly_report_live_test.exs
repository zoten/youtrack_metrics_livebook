defmodule YoutrackWeb.WeeklyReportLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders weekly report shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/weekly-report")

    assert has_element?(view, "#weekly-config-form")
    assert has_element?(view, "#build-weekly-report")
    assert has_element?(view, "#clear-weekly-cache")
    assert has_element?(view, "#toggle-weekly-config")
  end

  test "toggles weekly report configuration", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/weekly-report")

    assert has_element?(view, "#weekly-config-form")

    view
    |> element("#toggle-weekly-config")
    |> render_click()

    refute has_element?(view, "#weekly-config-form")
  end

  test "shows validation error when week start is blank", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/weekly-report")

    view
    |> element("#weekly-config-form")
    |> render_change(%{
      "config" => %{
        "base_url" => "https://example.youtrack.cloud",
        "token" => "token",
        "base_query" => "project: DEMO",
        "report_week_start" => ""
      }
    })

    view
    |> element("#build-weekly-report")
    |> render_click()

    assert has_element?(view, ".metrics-card", "Week start is required")
  end

  test "switches tabs after synthetic report result", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/weekly-report")

    report_data = %{
      report_payload: %{},
      report_json: "{}",
      weekly_json: "{}",
      daily_json: "{}",
      fetch_cache_state: :hit,
      summary_rows: [%{window: "Weekly", issues: 1, completed: 1}]
    }

    send(view.pid, {make_ref(), {:ok, {:report, report_data}}})

    assert has_element?(view, "button[phx-value-tab='summary']")

    view
    |> element("button[phx-value-tab='json']")
    |> render_click()

    assert has_element?(view, "pre", "{}")
    assert has_element?(view, "#weekly-cache-state", "Last fetch source: cache hit")
  end
end
