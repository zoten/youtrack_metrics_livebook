defmodule YoutrackWeb.PairingLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders pairing shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pairing")

    assert has_element?(view, "#pairing-config-form")
    assert has_element?(view, "#fetch-pairing-data")
    assert has_element?(view, "#reload-pairing-config")
    assert has_element?(view, "#clear-pairing-cache")
    assert has_element?(view, "#toggle-pairing-config")
  end

  test "toggles pairing configuration", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pairing")

    assert has_element?(view, "#pairing-config-form")

    view
    |> element("#toggle-pairing-config")
    |> render_click()

    refute has_element?(view, "#pairing-config-form")
  end

  test "shows validation error when base query is blank", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pairing")

    view
    |> element("#pairing-config-form")
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

    assert has_element?(view, "#pairing-config-form")
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
end
