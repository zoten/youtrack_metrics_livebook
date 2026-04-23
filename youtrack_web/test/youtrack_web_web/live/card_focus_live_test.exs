defmodule YoutrackWeb.CardFocusLiveTest do
  use YoutrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders card focus shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/card")

    assert has_element?(view, "#theme-toggle")
    assert has_element?(view, "#sidebar-shared-config-form")
    assert has_element?(view, "#nav-card_focus")
    assert has_element?(view, "#card-focus-search-form")
    assert has_element?(view, "#card-focus-open")
    assert has_element?(view, "#card-focus-state-timeline")
    assert has_element?(view, "#card-focus-current-issue", "No card selected")
  end

  test "reads issue id from route params", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/card/PROJ-42")

    assert has_element?(view, "#card-focus-current-issue", "PROJ-42")

    assert has_element?(
             view,
             "#card-focus-search-form input[name='lookup[issue_id]'][value='PROJ-42']"
           )
  end

  test "shows validation error when issue id is blank", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/card")

    view
    |> element("#card-focus-search-form")
    |> render_submit(%{"lookup" => %{"issue_id" => "   "}})

    assert has_element?(view, "#card-focus-lookup-error", "Issue ID is required")
  end

  test "navigates to deep-link route when issue id is submitted", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/card")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("#card-focus-search-form", %{"lookup" => %{"issue_id" => "PROJ-77"}})
             |> render_submit()

    assert to == "/card/PROJ-77"
  end

  test "renders chart timeline after synthetic card fetch", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/card/PROJ-88")

    card_data = %{
      issue: %{
        issue_key: "PROJ-88",
        title: "Synthetic card",
        project: "PROJ",
        type: "Task",
        state: "In Progress",
        status: "ongoing",
        workstreams: ["BACKEND"],
        assignees: ["Alice"],
        tags: ["team:backend"],
        created: 1_000
      },
      metrics: %{
        cycle_time_ms: 10_000,
        net_active_time_ms: 8_000,
        inactive_time_ms: 2_000,
        active_ratio_pct: 80.0,
        comment_count: 1,
        rework_count: 0
      },
      active_segments: [
        %{label: "Active", tone: "active", start_ms: 1_000, end_ms: 9_000, duration_ms: 8_000}
      ],
      state_segments: [
        %{state: "Backlog", start_ms: 1_000, end_ms: 3_000, duration_ms: 2_000},
        %{state: "In Progress", start_ms: 3_000, end_ms: 9_000, duration_ms: 6_000},
        %{state: "Review", start_ms: 9_000, end_ms: 11_000, duration_ms: 2_000}
      ],
      time_in_state: [%{state: "In Progress", duration_ms: 8_000}],
      state_events: [],
      assignee_events: [],
      comment_events: [],
      tag_events: [],
      description_events: [],
      rework_events: [],
      timeline_events: []
    }

    send(view.pid, {make_ref(), {:ok, %{card_data: card_data, fetch_cache_state: :hit}}})

    assert has_element?(view, "#card-focus-state-gantt")
    assert has_element?(view, "#card-focus-state-gantt-card")
    assert has_element?(view, "#card-focus-toggle-exclude-todo")
    assert has_element?(view, "#card-focus-toggle-exclude-no-sprint")
    assert has_element?(view, "#card-focus-compare-link")
    assert has_element?(view, "a[href='/compare?ids=PROJ-88']")
  end

  test "exclude todo toggle removes todo segments from timeline chart", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/card/PROJ-99")

    card_data = %{
      issue: %{
        issue_key: "PROJ-99",
        title: "Synthetic card",
        project: "PROJ",
        type: "Task",
        state: "In Progress",
        status: "ongoing",
        workstreams: ["BACKEND"],
        assignees: ["Alice"],
        tags: ["team:backend"],
        created: 1_000
      },
      metrics: %{
        cycle_time_ms: 12_000,
        net_active_time_ms: 8_000,
        inactive_time_ms: 4_000,
        active_ratio_pct: 66.7,
        comment_count: 1,
        rework_count: 0
      },
      active_segments: [
        %{label: "Active", tone: "active", start_ms: 1_000, end_ms: 11_000, duration_ms: 10_000}
      ],
      state_segments: [
        %{
          state: "To Do",
          start_ms: 1_000,
          end_ms: 6_000,
          duration_ms: 5_000,
          has_sprint?: false,
          sprint_names: []
        },
        %{
          state: "In Progress",
          start_ms: 6_000,
          end_ms: 11_000,
          duration_ms: 5_000,
          has_sprint?: true,
          sprint_names: ["Sprint 12"]
        }
      ],
      time_in_state: [%{state: "In Progress", duration_ms: 5_000}],
      state_events: [],
      assignee_events: [],
      comment_events: [],
      tag_events: [],
      description_events: [],
      rework_events: [],
      timeline_events: []
    }

    send(view.pid, {make_ref(), {:ok, %{card_data: card_data, fetch_cache_state: :hit}}})

    initial_html = render(view)
    assert initial_html =~ "To Do"

    view
    |> element("#card-focus-toggle-exclude-todo")
    |> render_click()

    filtered_html = render(view)
    refute filtered_html =~ "&quot;label&quot;:&quot;To Do&quot;"
    assert filtered_html =~ "&quot;label&quot;:&quot;In Progress&quot;"
  end
end
