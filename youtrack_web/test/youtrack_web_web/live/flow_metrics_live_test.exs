defmodule YoutrackWeb.FlowMetricsLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders flow metrics shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

    assert has_element?(view, "#theme-toggle")
    assert has_element?(view, "#theme-dark")
    assert has_element?(view, "#flow-config-form")
    assert has_element?(view, "#fetch-flow-data")
    assert has_element?(view, "#reload-flow-config")
    assert has_element?(view, "#clear-flow-cache")
    assert has_element?(view, "#toggle-flow-config")
    assert has_element?(view, "#flow-config-form input[name='config[base_url]']")
  end

  test "toggles configuration panel visibility", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

    assert has_element?(view, "#flow-config-form")

    view
    |> element("#toggle-flow-config")
    |> render_click()

    refute has_element?(view, "#flow-config-form")

    view
    |> element("#toggle-flow-config")
    |> render_click()

    assert has_element?(view, "#flow-config-form")
  end

  test "reads persisted config visibility from connect params", %{conn: conn} do
    conn = put_connect_params(conn, %{"config_open" => "false"})
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

    refute has_element?(view, "#flow-config-form")
  end

  test "shows validation error when base query is blank", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow-metrics")

    view
    |> element("#flow-config-form")
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

    assert has_element?(view, "#flow-config-form")
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
end
