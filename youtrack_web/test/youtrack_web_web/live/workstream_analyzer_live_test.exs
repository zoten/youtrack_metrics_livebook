defmodule YoutrackWeb.WorkstreamAnalyzerLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders workstream analyzer shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workstream-analyzer")

    assert has_element?(view, "#theme-toggle")
    assert has_element?(view, "#sidebar-shared-config-form")
    assert has_element?(view, "#fetch-workstream-analyzer-data")
    assert has_element?(view, "#reload-workstream-analyzer-config")
    assert has_element?(view, "#clear-workstream-analyzer-cache")
    assert has_element?(view, "#toggle-workstream-analyzer-config")
    assert has_element?(view, "#workstream-analyzer-mode-compare")
    assert has_element?(view, "#workstream-analyzer-mode-composition")
  end

  test "toggles configuration panel visibility", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workstream-analyzer")

    assert has_element?(view, "#sidebar-shared-config-form")

    view
    |> element("#toggle-workstream-analyzer-config")
    |> render_click()

    refute has_element?(view, "#sidebar-shared-config-form")

    view
    |> element("#toggle-workstream-analyzer-config")
    |> render_click()

    assert has_element?(view, "#sidebar-shared-config-form")
  end

  test "reads shared config from connect params", %{conn: conn} do
    conn =
      put_connect_params(conn, %{
        "shared_config" => %{"effort_mappings_path" => "../custom_effort_mappings.yaml"}
      })

    {:ok, view, _html} = live(conn, ~p"/workstream-analyzer")

    assert has_element?(
             view,
             "#sidebar-shared-config-form input[name='config[effort_mappings_path]'][value='../custom_effort_mappings.yaml']"
           )
  end

  test "shows validation error when base query is blank", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workstream-analyzer")

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
    |> element("#fetch-workstream-analyzer-data")
    |> render_click()

    assert has_element?(view, ".metrics-card", "Base query is required")
  end

  test "renders analyzer charts from async payload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workstream-analyzer")

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
          chart_specs: %{compare_effort: chart_spec, composition_effort: chart_spec},
          metrics: %{total_issues: 10, total_work_items: 8},
          fetch_cache_state: :miss,
          available_streams: ["Backend", "Frontend"],
          selected_streams: ["Backend", "Frontend"],
          parent_stream: "Backend",
          mode: "compare",
          normalization_diagnostics: %{
            mapped_by_field: %{"Story Points" => 7},
            unmapped_by_reason: %{missing_rule: 1},
            unmapped_samples: [
              %{
                issue_id: "PROJ-9",
                source_field: "Size",
                source_value: "hard",
                reason: :missing_rule
              }
            ]
          },
          cached_work_items: [%{issue_id: "PROJ-1", stream: "Backend", start_at: 1, end_at: 2}],
          cached_normalized_results: [%{issue_id: "PROJ-1", status: :mapped, score: 3.0}],
          cached_rules: %{}
        }}}
    )

    assert has_element?(view, "#chart-workstream-compare")
    assert has_element?(view, "#workstream-analyzer-cache-state", "Last fetch source: cache miss")
    assert has_element?(view, "#workstream-analyzer-diagnostics")
    assert has_element?(view, "#workstream-analyzer-effort-mappings-path")
    assert render(view) =~ "PROJ-9"
  end

  test "select all and unselect all update compare workstream checkboxes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workstream-analyzer")

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
          chart_specs: %{compare_effort: chart_spec, composition_effort: chart_spec},
          metrics: %{total_issues: 10, total_work_items: 8},
          fetch_cache_state: :miss,
          available_streams: ["Backend", "Frontend"],
          selected_streams: ["Backend"],
          parent_stream: "Backend",
          mode: "compare",
          normalization_diagnostics: %{},
          cached_work_items: [
            %{issue_id: "PROJ-1", stream: "Backend", start_at: 1, end_at: 2},
            %{issue_id: "PROJ-2", stream: "Frontend", start_at: 1, end_at: 2}
          ],
          cached_normalized_results: [
            %{issue_id: "PROJ-1", status: :mapped, score: 3.0},
            %{issue_id: "PROJ-2", status: :mapped, score: 5.0}
          ],
          cached_rules: %{}
        }}}
    )

    assert has_element?(
             view,
             "#workstream-analyzer-stream-filter input[name='selected_streams[]'][value='Backend'][checked]"
           )

    refute has_element?(
             view,
             "#workstream-analyzer-stream-filter input[name='selected_streams[]'][value='Frontend'][checked]"
           )

    view
    |> element("#workstream-analyzer-select-all-streams")
    |> render_click()

    assert has_element?(
             view,
             "#workstream-analyzer-stream-filter input[name='selected_streams[]'][value='Backend'][checked]"
           )

    assert has_element?(
             view,
             "#workstream-analyzer-stream-filter input[name='selected_streams[]'][value='Frontend'][checked]"
           )

    view
    |> element("#workstream-analyzer-unselect-all-streams")
    |> render_click()

    refute has_element?(
             view,
             "#workstream-analyzer-stream-filter input[name='selected_streams[]'][value='Backend'][checked]"
           )

    refute has_element?(
             view,
             "#workstream-analyzer-stream-filter input[name='selected_streams[]'][value='Frontend'][checked]"
           )
  end
end
