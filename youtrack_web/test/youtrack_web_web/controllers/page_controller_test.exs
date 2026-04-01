defmodule YoutrackWeb.PageControllerTest do
  use YoutrackWeb.ConnCase

  test "GET / returns the dashboard shell", %{conn: conn} do
    conn = get(conn, ~p"/")

    html = html_response(conn, 200)

    assert html =~ "YouTrack Metrics"
    assert html =~ "Flow Metrics"
  end
end
