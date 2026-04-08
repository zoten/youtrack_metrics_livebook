defmodule YoutrackWeb.PairingLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders pairing shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pairing")

    assert has_element?(view, "#sidebar-shared-config-form")
    assert has_element?(view, "#fetch-pairing-data")
    assert has_element?(view, "#reload-pairing-config")
    assert has_element?(view, "#clear-pairing-cache")
    assert has_element?(view, "#toggle-pairing-config")
  end

  test "toggles pairing configuration", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pairing")

    assert has_element?(view, "#sidebar-shared-config-form")

    view
    |> element("#toggle-pairing-config")
    |> render_click()

    refute has_element?(view, "#sidebar-shared-config-form")
  end

  test "shows validation error when base query is blank", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pairing")

    view
    |> element("#sidebar-shared-config-form")
    |> render_change(%{
      "config" => %{
        "base_url" => "https://example.youtrack.cloud",
        "token" => "token",
        "base_query" => ""
      }
    })

    view
    |> element("#fetch-pairing-data")
    |> render_click()

    assert has_element?(view, ".metrics-card", "Base query is required")
  end

  test "reloads env-backed defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pairing")

    view
    |> element("#reload-pairing-config")
    |> render_click()

    assert has_element?(view, "#sidebar-shared-config-form")
  end

  test "applies async result payload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pairing")

    send(
      view.pid,
      {make_ref(),
       {:ok, %{chart_specs: %{}, metrics: %{total_issues: 42}, fetch_cache_state: :miss}}}
    )

    assert has_element?(view, ".metrics-grid", "42")
    assert has_element?(view, "#pairing-cache-state", "Last fetch source: cache miss")
  end

  test "renders pairing chart cards from async payload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pairing")

    chart_spec = %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "data" => %{"values" => [%{"value" => 1}]},
      "mark" => "bar",
      "encoding" => %{
        "x" => %{"field" => "value", "type" => "quantitative"},
        "y" => %{"aggregate" => "count", "type" => "quantitative"}
      }
    }

    send(
      view.pid,
      {make_ref(),
       {:ok,
        %{
          chart_specs: %{
            pair_matrix: chart_spec,
            pairing_trend: chart_spec,
            pairing_by_workstream: chart_spec,
            top_pairs: chart_spec,
            firefighter_person: chart_spec,
            firefighter_pair: chart_spec,
            interrupt_aggregate: chart_spec,
            interrupt_person: chart_spec,
            planned_unplanned: chart_spec,
            involvement_by_person: chart_spec,
            pairing_by_project: chart_spec
          },
          metrics: %{total_issues: 42},
          fetch_cache_state: :miss
        }}}
    )

    assert has_element?(view, "#pairing-charts-area")
    assert has_element?(view, "#pairing-matrix-chart")
    assert has_element?(view, "#pairing-matrix-chart-card")
    assert has_element?(view, "#pairing-trend-chart")
    assert has_element?(view, "#pairing-by-project-chart")
  end
end
