defmodule YoutrackWeb.FlowMetricsLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders flow metrics shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

    assert has_element?(view, "#theme-toggle")
    assert has_element?(view, "#theme-dark")
    assert has_element?(view, "#sidebar-shared-config-form")
    assert has_element?(view, "#fetch-flow-data")
    assert has_element?(view, "#reload-flow-config")
    assert has_element?(view, "#clear-flow-cache")
    assert has_element?(view, "#toggle-flow-config")
    assert has_element?(view, "#sidebar-shared-config-form input[name='config[base_url]']")
  end

  test "toggles configuration panel visibility", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

    assert has_element?(view, "#sidebar-shared-config-form")

    view
    |> element("#toggle-flow-config")
    |> render_click()

    refute has_element?(view, "#sidebar-shared-config-form")

    view
    |> element("#toggle-flow-config")
    |> render_click()

    assert has_element?(view, "#sidebar-shared-config-form")
  end

  test "reads persisted config visibility from connect params", %{conn: conn} do
    conn = put_connect_params(conn, %{"config_open" => "false"})
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

    refute has_element?(view, "#sidebar-shared-config-form")
  end

  test "reads shared config from connect params", %{conn: conn} do
    conn = put_connect_params(conn, %{"shared_config" => %{"base_query" => "project: SHARED"}})
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

    assert has_element?(
             view,
             "#sidebar-shared-config-form input[name='config[base_query]'][value='project: SHARED']"
           )
  end

  test "shows validation error when base query is blank", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

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
    |> element("#fetch-flow-data")
    |> render_click()

    assert has_element?(view, ".metrics-card", "Base query is required")
  end

  test "reloads env-backed defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

    view
    |> element("#reload-flow-config")
    |> render_click()

    assert has_element?(view, "#sidebar-shared-config-form")
    assert has_element?(view, "#fetch-flow-data")
  end

  test "shows and clears activities progress through handle_info", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

    send(view.pid, {:activities_progress, 3, 9})

    assert has_element?(view, "#activities-progress", "Activities progress: 3/9")

    send(
      view.pid,
      {make_ref(), {:ok, %{chart_specs: %{}, metrics: %{}, fetch_cache_state: :hit}}}
    )

    assert has_element?(view, "#flow-cache-state", "Last fetch source: cache hit")

    refute has_element?(view, "#activities-progress")
  end

  test "renders flow chart cards from async payload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

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
            throughput: chart_spec,
            throughput_by_person: chart_spec,
            cycle_histogram: chart_spec,
            cycle_by_stream: chart_spec,
            net_active_histogram: chart_spec,
            net_active_by_stream: chart_spec,
            cycle_vs_net_active: chart_spec,
            wip_by_person: chart_spec,
            wip_by_stream: chart_spec,
            context_switch_avg: chart_spec,
            context_switch_heatmap: chart_spec,
            bus_factor: chart_spec,
            long_running: chart_spec,
            rotation_switches: chart_spec,
            rotation_tenure: chart_spec,
            rotation_person_stream: chart_spec,
            rotation_transition_sankey: chart_spec,
            rotation_stream_tenure: chart_spec,
            rework_by_stream: chart_spec,
            unplanned_by_stream: chart_spec,
            unplanned_by_person: chart_spec,
            unplanned_trend: chart_spec
          },
          metrics: %{total_issues: 10, total_work_items: 8},
          fetch_cache_state: :miss
        }}}
    )

    assert has_element?(view, "#flow-charts-area")
    assert has_element?(view, "#chart-throughput")
    assert has_element?(view, "#chart-throughput-card")
    assert has_element?(view, "#chart-context-heat")
    assert has_element?(view, "#chart-rotation-sankey")
    assert has_element?(view, "#chart-unplanned-trend")
    assert has_element?(view, "#flow-cache-state", "Last fetch source: cache miss")
  end
end
