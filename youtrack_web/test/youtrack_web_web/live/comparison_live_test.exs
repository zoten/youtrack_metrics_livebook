defmodule YoutrackWeb.ComparisonLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders comparison shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare")

    assert has_element?(view, "#theme-toggle")
    assert has_element?(view, "#sidebar-shared-config-form")
    assert has_element?(view, "#nav-comparison")
    assert has_element?(view, "#comparison-card-selector")
    assert has_element?(view, "#comparison-add-cards")
    assert has_element?(view, "#comparison-issue-ids")
  end

  test "reads issue ids from query params", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare?ids=PROJ-10,PROJ-11")

    assert has_element?(
             view,
             "#comparison-card-selector input[name='selector[issue_ids]'][value='PROJ-10, PROJ-11']"
           )

    assert has_element?(view, "#comparison-remove-PROJ-10")
    assert has_element?(view, "#comparison-remove-PROJ-11")
  end

  test "adds cards and deduplicates existing values", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare?ids=PROJ-10")

    view
    |> form("#comparison-card-selector", %{
      "selector" => %{"issue_ids" => "PROJ-10, PROJ-11, PROJ-12"}
    })
    |> render_submit()

    assert has_element?(view, "#comparison-remove-PROJ-10")
    assert has_element?(view, "#comparison-remove-PROJ-11")
    assert has_element?(view, "#comparison-remove-PROJ-12")
  end

  test "shows max cards validation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare")

    view
    |> form("#comparison-card-selector", %{
      "selector" => %{"issue_ids" => "PROJ-1, PROJ-2, PROJ-3, PROJ-4, PROJ-5"}
    })
    |> render_submit()

    assert has_element?(view, "#comparison-selector-error", "Maximum 4 cards allowed")
    assert has_element?(view, "#comparison-remove-PROJ-1")
    assert has_element?(view, "#comparison-remove-PROJ-4")
    refute has_element?(view, "#comparison-remove-PROJ-5")
  end

  test "removes selected card", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare?ids=PROJ-50,PROJ-51")

    view
    |> element("#comparison-remove-PROJ-50")
    |> render_click()

    refute has_element?(view, "#comparison-remove-PROJ-50")
    assert has_element?(view, "#comparison-remove-PROJ-51")
  end

  test "issue key pills link back to card focus", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare?ids=PROJ-50,PROJ-51")

    assert has_element?(view, "a[href='/card/PROJ-50']")
    assert has_element?(view, "a[href='/card/PROJ-51']")
  end

  test "shows selector validation when no cards are selected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare")

    view
    |> form("#comparison-card-selector", %{"selector" => %{"issue_ids" => "   "}})
    |> render_submit()

    assert has_element?(view, "#comparison-selector-error", "At least one issue ID is required")
  end

  test "renders incremental async results and per-card errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare?ids=PROJ-88,PROJ-89")

    card_data = %{
      issue: %{
        issue_key: "PROJ-88",
        title: "Synthetic issue",
        project: "PROJ",
        type: "Task",
        state: "In Progress",
        status: "ongoing",
        workstreams: [],
        assignees: [],
        tags: [],
        created: 1_000
      },
      metrics: %{
        cycle_time_ms: 10_000,
        net_active_time_ms: 8_000,
        inactive_time_ms: 2_000,
        active_ratio_pct: 80.0,
        comment_count: 0,
        rework_count: 0
      },
      active_segments: [],
      state_segments: [],
      time_in_state: [],
      state_events: [],
      assignee_events: [],
      comment_events: [],
      tag_events: [],
      description_events: [],
      rework_events: [],
      timeline_events: []
    }

    send(view.pid, {make_ref(), {:ok, %{issue_id: "PROJ-88", card_data: card_data}}})

    assert has_element?(view, "#comparison-results")
    assert has_element?(view, "#comparison-results", "1 of 2 cards loaded")

    send(
      view.pid,
      {make_ref(), {:error, %{issue_id: "PROJ-89", reason: "Issue not found: PROJ-89"}}}
    )

    assert has_element?(view, "#comparison-error", "Comparison fetch failed for PROJ-89")
    assert has_element?(view, "#comparison-errors-by-card", "PROJ-89")
  end

  test "renders shared gantt chart when at least two cards are loaded", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare?ids=PROJ-88,PROJ-89")

    card_data_1 = %{
      issue: %{
        issue_key: "PROJ-88",
        title: "Synthetic issue 1",
        project: "PROJ",
        type: "Task",
        state: "In Progress",
        status: "ongoing",
        workstreams: [],
        assignees: [],
        tags: [],
        created: 1_000
      },
      metrics: %{
        cycle_time_ms: 10_000,
        net_active_time_ms: 8_000,
        inactive_time_ms: 2_000,
        active_ratio_pct: 80.0,
        comment_count: 0,
        rework_count: 0
      },
      active_segments: [
        %{label: "Active", start_ms: 2_000, end_ms: 6_000, duration_ms: 4_000}
      ],
      state_segments: [
        %{state: "Backlog", start_ms: 1_000, end_ms: 2_000, duration_ms: 1_000},
        %{state: "In Progress", start_ms: 2_000, end_ms: 7_000, duration_ms: 5_000}
      ],
      time_in_state: [],
      state_events: [],
      assignee_events: [],
      comment_events: [],
      tag_events: [],
      description_events: [],
      rework_events: [],
      timeline_events: []
    }

    card_data_2 = %{
      issue: %{
        issue_key: "PROJ-89",
        title: "Synthetic issue 2",
        project: "PROJ",
        type: "Task",
        state: "Review",
        status: "ongoing",
        workstreams: [],
        assignees: [],
        tags: [],
        created: 2_000
      },
      metrics: %{
        cycle_time_ms: 12_000,
        net_active_time_ms: 9_000,
        inactive_time_ms: 3_000,
        active_ratio_pct: 75.0,
        comment_count: 1,
        rework_count: 0
      },
      active_segments: [
        %{label: "On Hold", start_ms: 6_000, end_ms: 7_000, duration_ms: 1_000}
      ],
      state_segments: [
        %{state: "In Progress", start_ms: 3_000, end_ms: 6_000, duration_ms: 3_000},
        %{state: "Review", start_ms: 6_000, end_ms: 8_000, duration_ms: 2_000}
      ],
      time_in_state: [],
      state_events: [],
      assignee_events: [],
      comment_events: [],
      tag_events: [],
      description_events: [],
      rework_events: [],
      timeline_events: []
    }

    send(view.pid, {make_ref(), {:ok, %{issue_id: "PROJ-88", card_data: card_data_1}}})
    send(view.pid, {make_ref(), {:ok, %{issue_id: "PROJ-89", card_data: card_data_2}}})

    assert has_element?(view, "#comparison-gantt")
    assert has_element?(view, "#comparison-gantt-card")
    assert has_element?(view, "#comparison-state-events")
    assert has_element?(view, "#comparison-state-events-card")
    assert has_element?(view, "#comparison-comments")
    assert has_element?(view, "#comparison-comments-card")
    assert has_element?(view, "#comparison-tags")
    assert has_element?(view, "#comparison-tags-card")
    assert has_element?(view, "#comparison-metrics")
    assert has_element?(view, "#comparison-metrics-row-PROJ-88")
    assert has_element?(view, "#comparison-metrics-row-PROJ-89")

    assert has_element?(
             view,
             "#comparison-results",
             "Shared Gantt timeline and metrics comparison table are ready"
           )
  end

  test "renders metrics comparison table with one card loaded", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare?ids=PROJ-88")

    card_data = %{
      issue: %{
        issue_key: "PROJ-88",
        title: "Synthetic issue",
        project: "PROJ",
        type: "Task",
        state: "In Progress",
        status: "ongoing",
        workstreams: [],
        assignees: [],
        tags: [],
        created: 1_000
      },
      metrics: %{
        cycle_time_ms: 10_000,
        net_active_time_ms: 8_000,
        inactive_time_ms: 2_000,
        active_ratio_pct: 80.0,
        comment_count: 3,
        rework_count: 1
      },
      active_segments: [],
      state_segments: [],
      time_in_state: [],
      state_events: [],
      assignee_events: [],
      comment_events: [],
      tag_events: [],
      description_events: [],
      rework_events: [],
      timeline_events: []
    }

    send(view.pid, {make_ref(), {:ok, %{issue_id: "PROJ-88", card_data: card_data}}})

    assert has_element?(view, "#comparison-metrics")
    assert has_element?(view, "#comparison-metrics-row-PROJ-88")
    assert has_element?(view, "#comparison-metrics-row-PROJ-88", "PROJ-88")
  end
end
