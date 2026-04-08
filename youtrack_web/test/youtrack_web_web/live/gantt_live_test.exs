defmodule YoutrackWeb.GanttLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders gantt shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gantt")

    assert has_element?(view, "#sidebar-shared-config-form")
    assert has_element?(view, "#fetch-gantt-data")
    assert has_element?(view, "#reload-gantt-config")
    assert has_element?(view, "#clear-gantt-cache")
    assert has_element?(view, "#toggle-gantt-config")
  end

  test "toggles gantt configuration", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gantt")

    assert has_element?(view, "#sidebar-shared-config-form")

    view
    |> element("#toggle-gantt-config")
    |> render_click()

    refute has_element?(view, "#sidebar-shared-config-form")
  end

  test "shows validation error when token is blank", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gantt")

    view
    |> element("#sidebar-shared-config-form")
    |> render_change(%{
      "config" => %{
        "base_url" => "https://example.youtrack.cloud",
        "token" => "",
        "base_query" => "project: DEMO"
      }
    })

    view
    |> element("#fetch-gantt-data")
    |> render_click()

    assert has_element?(view, ".metrics-card", "Token is required")
  end

  test "reloads rules and env-backed defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gantt")

    view
    |> element("#reload-gantt-config")
    |> render_click()

    assert has_element?(view, "#sidebar-shared-config-form")
  end

  test "renders cache source from async payload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gantt")

    send(
      view.pid,
      {make_ref(),
       {:ok,
        %{
          rules: %{slug_prefix_to_stream: %{}},
          chart_specs: %{},
          raw_issues: [],
          unclassified_stats: [],
          work_items_count: 0,
          fetch_cache_state: :refresh
        }}}
    )

    assert has_element?(view, "#gantt-cache-state", "Last fetch source: refresh")
  end

  test "renders deep links for unclassified example cards", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gantt")

    send(
      view.pid,
      {make_ref(),
       {:ok,
        %{
          rules: %{slug_prefix_to_stream: %{}},
          chart_specs: %{},
          raw_issues: [],
          unclassified_stats: [%{slug: "API", count: 1, examples: ["PROJ-101"]}],
          work_items_count: 0,
          fetch_cache_state: :hit
        }}}
    )

    assert has_element?(view, "#gantt-unclassified-examples")
    assert has_element?(view, "#gantt-unclassified-card-PROJ-101")
  end
end
