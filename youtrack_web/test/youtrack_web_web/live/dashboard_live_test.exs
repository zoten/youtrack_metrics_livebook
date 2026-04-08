defmodule YoutrackWeb.DashboardLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the shared dashboard shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#theme-toggle")
    assert has_element?(view, "#theme-system")
    assert has_element?(view, "#sidebar-shared-config-form")
    assert has_element?(view, "#nav-flow_metrics")
    assert has_element?(view, "#dashboard-home-title", "Choose a live workflow")
    assert has_element?(view, "#open-flow_metrics")
  end

  test "hydrates shared config from connect params", %{conn: conn} do
    conn =
      put_connect_params(conn, %{"shared_config" => %{"base_url" => "https://cached.example"}})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#sidebar-shared-config-form input[name='config[base_url]'][value='https://cached.example']"
           )
  end

  test "shows direct links to implemented pages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert render(view) =~ "/flow-metrics"
    assert render(view) =~ "/gantt"
    assert render(view) =~ "/pairing"
    assert render(view) =~ "/weekly-report"
  end
end
