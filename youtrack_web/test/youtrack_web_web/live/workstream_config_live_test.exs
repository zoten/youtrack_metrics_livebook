defmodule YoutrackWeb.WorkstreamConfigLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders workstream config page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workstreams")

    assert has_element?(view, "#wsc-toggle-config")
    assert has_element?(view, "#wsc-fetch-data")
    assert has_element?(view, "#wsc-reload-config")
    assert has_element?(view, "#wsc-clear-cache")
    assert has_element?(view, "#wsc-yaml-editor")
    assert has_element?(view, "#wsc-yaml-textarea")
    assert has_element?(view, "#wsc-save-rules")
  end

  test "toggles config panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workstreams")

    # Config starts open by default (ConfigVisibilityPreference defaults to true)
    assert has_element?(view, "#sidebar-shared-config-form")

    view |> element("#wsc-toggle-config") |> render_click()

    refute has_element?(view, "#sidebar-shared-config-form")

    view |> element("#wsc-toggle-config") |> render_click()

    assert has_element?(view, "#sidebar-shared-config-form")
  end

  test "validates fetch config — shows error when token is blank", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workstreams")

    # Config is open by default — no need to click toggle first
    view
    |> element("#sidebar-shared-config-form")
    |> render_change(%{
      "config" => %{
        "base_url" => "https://example.youtrack.cloud",
        "token" => "",
        "base_query" => "project: DEMO"
      }
    })

    view |> element("#wsc-fetch-data") |> render_click()

    assert has_element?(view, ".metrics-card", "Token is required")
  end

  test "resetting async result updates unclassified stats and match stats", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workstreams")

    send(
      view.pid,
      {make_ref(),
       {:ok,
        %{
          raw_issues: [
            %{
              "id" => "1",
              "idReadable" => "TEST-1",
              "summary" => "[UNKNOWN] some task",
              "tags" => [],
              "type" => nil
            }
          ],
          unclassified_stats: [%{slug: "UNKNOWN", count: 1}],
          match_stats: [],
          fetch_cache_state: :miss
        }}}
    )

    assert has_element?(view, "#wsc-unclassified")
    assert has_element?(view, "#wsc-slug-row-UNKNOWN")

    assert has_element?(view, ".metrics-stat-value", "1")
  end

  test "clicking view issues shows paginated table for the slug", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workstreams")

    send(
      view.pid,
      {make_ref(),
       {:ok,
        %{
          raw_issues: [
            %{
              "id" => "1",
              "idReadable" => "TEST-1",
              "summary" => "[UNKNOWN] first",
              "tags" => [],
              "type" => nil
            },
            %{
              "id" => "2",
              "idReadable" => "TEST-2",
              "summary" => "[UNKNOWN] second",
              "tags" => [],
              "type" => nil
            }
          ],
          unclassified_stats: [%{slug: "UNKNOWN", count: 2}],
          match_stats: [],
          fetch_cache_state: :miss
        }}}
    )

    assert has_element?(view, "#wsc-slug-row-UNKNOWN")

    view
    |> element("#wsc-slug-row-UNKNOWN button", "View issues")
    |> render_click()

    assert has_element?(view, "#wsc-slug-row-UNKNOWN", "TEST-1")
    assert has_element?(view, "#wsc-slug-row-UNKNOWN", "TEST-2")

    view
    |> element("#wsc-slug-row-UNKNOWN button", "Hide")
    |> render_click()

    refute has_element?(view, "#wsc-slug-row-UNKNOWN", "TEST-1")
  end

  test "config summary section appears when match_stats are present", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workstreams")

    send(
      view.pid,
      {make_ref(),
       {:ok,
        %{
          raw_issues: [
            %{
              "id" => "1",
              "idReadable" => "TEST-1",
              "summary" => "[BACKEND] task",
              "tags" => [],
              "type" => nil
            }
          ],
          unclassified_stats: [],
          match_stats: [%{stream: "BACKEND", rule_type: :slug, rule_value: "BACKEND", count: 1}],
          fetch_cache_state: :hit
        }}}
    )

    assert has_element?(view, "#wsc-match-summary")
    assert has_element?(view, "#wsc-match-summary", "BACKEND")
    assert has_element?(view, "#wsc-match-summary", "slug")
  end
end
