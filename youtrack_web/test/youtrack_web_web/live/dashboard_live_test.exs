defmodule YoutrackWeb.DashboardLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the shared dashboard shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#shared-config-form")
    assert has_element?(view, "#nav-flow_metrics[aria-current='page']")
    assert has_element?(view, "#current-section-title")
  end

  test "switches sections through live patch navigation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#nav-pairing")
    |> render_click()

    assert has_element?(view, "#nav-pairing[aria-current='page']")
    assert has_element?(view, "#current-section-title", "Pairing")
  end
end
