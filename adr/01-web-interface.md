## Plan: Phoenix LiveView Dashboard for YouTrack Metrics

### Implementation Status (2026-04-01)

- Phase 1: completed
- Phase 2: completed
- Phase 3.1 Flow Metrics: completed (charts + async fetch + activities progress)
- Phase 3.2 Gantt: completed (classifier + rules export + 7 visualizations)
- Phase 3.3 Pairing: completed (pair matrix, firefighter views, interrupt trends)
- Phase 3.4 Weekly Report: completed (payload generation, tabbed outputs, optional LLM call)
- Phase 4.1 Async progress: completed (activities progress indicator in Flow Metrics)
- Phase 4.2 ETS caching: completed (shared issue cache with TTL + refresh bypass buttons)
- Phase 4 polish: completed (cache source badge + clear-cache controls in all sections)
- Phase 4.3 Runtime config reload: completed (toolbar "Reload Configuration" action to re-read `.env` and `workstreams.yaml`)
- Phase 5: completed (multi-stage release Dockerfile + production compose + mounted shared inputs)

### Incremental Status (2026-04-08)

- Phase 1-3 follow-up: completed
  - Shared config boundary implemented (`YoutrackWeb.Configuration.shared_fields/0` + merge helpers)
  - Shared sidebar form is now the single source of truth for cross-page config inputs
  - LocalStorage bridge implemented for shared config persistence across page switches/reconnects
  - Per-page duplicated shared forms removed from section pages
  - Weekly report keeps report+LLM fields local to the page form (not shared globally)
  - Weekly report Copy/Download tab now exposes daily, weekly, and full payload copy actions alongside the existing downloads
  - LiveView tests updated for all affected pages
- Phase 3.1 Flow Metrics rotation visualization: completed (2026-04-13)
  - Replaced the old single Person × Week heatmap with faceted per-person timelines so parallel streams and switching are directly comparable.
  - Added a secondary Sankey chart summarizing consecutive-week transitions across all streams touched.
  - Kept the existing stream-tenure view as supporting context, rather than the primary rotation visualization.
  - Upgraded the chart renderer path to support full Vega specs in addition to Vega-Lite.
- Phase 3.5 Card Focus: in progress
  - New `/card` and `/card/:issue_id` LiveView routes added for issue-level deep dives
  - Card page reuses shared config/sidebar patterns instead of adding a page-local fetch form
  - Initial card analytics pipeline implemented in `Youtrack.CardFocus`, reusing `Youtrack.WeeklyReport` and `Youtrack.Rework`
  - Current page renders issue snapshot, cycle/net active timing, time-in-state, and state/assignee/tag/comment/description histories
- Phase 3.1 Flow Metrics UX: completed
  - Added default-collapsed “project definition” explainers for Cycle Time and Net Active Time directly above their distribution/by-stream charts

Create a standalone Phoenix LiveView app (`youtrack_web/`) that coexists with the existing Livebook notebooks, sharing the `youtrack/` library via path dependency. The app provides a single-page dashboard with sidebar navigation across analytical sections (Flow Metrics, Gantt, Pairing, Weekly Report, Card Focus, Workstream Config), rendering VegaLite specs via a `vega-embed` JS hook where charts are needed, with form-based configuration replacing Kino inputs. Both apps share `workstreams.yaml`, env vars, and `prompts/`. Docker-compose runs both services side by side.

---

### Phase 1: Project Scaffold & Shared Infrastructure

**Step 1.1 — Generate Phoenix project**
- `mix phx.new youtrack_web` inside repo
  - let's keep the dependencies for future iterations, just let's use sqlite as db backend (like for local configurations but avoiding postgres' compelxity)
- Add `{:youtrack, path: "../youtrack"}` and `{:vega_lite, "~> 0.1"}` to deps

**Step 1.2 — Runtime configuration** *(parallel with 1.3–1.5)*
- In `config/runtime.exs`, read same env vars as Livebooks (`YOUTRACK_BASE_URL`, `YOUTRACK_TOKEN`, etc.) — these become form defaults

**Step 1.3 — Shared config form component** *(parallel with 1.2, 1.4, 1.5)*
- Create `ConfigForm` LiveComponent mapping each Kino input type to a Phoenix form field
- Collapsible panel at top of each section; defaults from env vars

**Step 1.4 — VegaLite JS hook** *(parallel with 1.2, 1.3, 1.5)*
- Install `vega-embed` npm package
- JS hook receives JSON spec via `phx-hook`, renders with `vegaEmbed(el, spec)`
- Elixir wrapper component: `<.chart id={@id} spec={@spec} />`

**Step 1.5 — Data table component** *(parallel with 1.2, 1.3, 1.4)*
- Sortable, paginated Tailwind table replacing `Kino.DataTable`

### Phase 2: Layout & Navigation Shell

**Step 2.1 — Dashboard layout with sidebar** *(depends on 1.1)*
- `DashboardLive` at `/` with 4 sidebar nav items
- `live_patch` for section switching (no full reload)
- Shared config (credentials, base query) stored in root assigns, passed to sections
- Dark sidebar, light content area, responsive

### Phase 3: Section Implementation *(all 4 parallel, depend on Phase 1+2)*

Each section follows: mount → load defaults + workstream rules → config form → "Fetch Data" button → async Task → results in assigns → charts + tables render.

**Step 3.1 — Flow Metrics** (`FlowMetricsLive`)
- 13 config inputs, 21 visualizations grouped by PETALS dimensions (Progress, Energy, Togetherness, Autonomy)
- Pipeline: `Client.fetch_issues!` → optionally `fetch_activities!` (8 concurrent) → `WorkItems.build` → `Rework.count_by_issue` → `Rotation.*` metrics
- Build VegaLite specs server-side (same DSL as `flow_metrics.livemd`), serialize to JSON

**Step 3.2 — Gantt** (`GanttLive`)
- 12 inputs + editable stream_rules textarea
- Interactive classifier: LiveView assigns replace Agent — dropdown to map unclassified slugs → re-render charts
- "Export Rules" button to show updated rules as YAML
- 7 visualizations

**Step 3.3 — Pairing** (`PairingLive`)
- 9 inputs, 10 visualizations
- Pipeline: `Client.fetch_issues!` → `PairingAnalysis.extract_pairs` → `pair_matrix`, `trend_by_week`, `firefighters_*`

**Step 3.4 — Weekly Report** (`WeeklyReportLive`)
- 17 inputs (most complex section)
- Report generation: `WeeklyReport.build_issue_summary` → JSON payload → prompt template substitution
- Tabbed output: Summary, JSON preview, Payload tree, Copy/Download
- LLM integration: configurable endpoint, "Send to LLM" button, streaming response

### Phase 4: Async Fetch & Caching

**Step 4.1 — Async fetch with progress** *(depends on any 3.x)*
- `Task.async` supervised by LiveView; loading spinner during fetch
- Progress indicator for activity fetching ("42/120 issues")

**Step 4.2 — ETS caching (optional)** *(depends on 4.1)*
- Cache fetched issues in ETS keyed by `{query, days_back}` with TTL
- Avoids redundant API calls when switching sections; "Refresh" bypasses cache

### Phase 5: Docker & Deployment *(parallel with Phase 3)*

**Step 5.1 — Update `docker-compose.yml`** — add `phoenix` service on port 4000, `env_file: .env`, volumes for `workstreams.yaml` + `prompts/`

**Step 5.2 — Dockerfile** for Phoenix (multi-stage or dev-mode `elixir:1.19`)

**Step 5.3 — Shared file paths** — `WORKSTREAMS_PATH` and `PROMPTS_PATH` env vars, defaulting to `../workstreams.yaml` and `../prompts/`

---

### Architecture

```
youtrack_metrics_livebook/
├── youtrack/                     # Shared library (unchanged)
│   ├── lib/youtrack/...
│   ├── mix.exs
│   └── test/...
├── youtrack_web/                 # NEW: Phoenix LiveView app
│   ├── mix.exs                   # deps: {:youtrack, path: "../youtrack"}, :phoenix, :phoenix_live_view, :vega_lite, :tailwind
│   ├── lib/
│   │   ├── youtrack_web/
│   │   │   ├── application.ex
│   │   │   ├── endpoint.ex
│   │   │   ├── router.ex
│   │   │   ├── components/       # Shared UI components
│   │   │   │   ├── layouts.ex
│   │   │   │   ├── core_components.ex
│   │   │   │   ├── chart_component.ex      # VegaLite JS hook wrapper
│   │   │   │   ├── config_form.ex          # Shared config form (replaces Kino inputs)
│   │   │   │   └── data_table.ex           # Sortable data table component
│   │   │   ├── live/
│   │   │   │   ├── dashboard_live.ex       # Root LiveView (sidebar + section switching)
│   │   │   │   ├── flow_metrics_live.ex    # Flow Metrics section
│   │   │   │   ├── gantt_live.ex           # Gantt section (with classifier)
│   │   │   │   ├── pairing_live.ex         # Pairing section
│   │   │   │   └── weekly_report_live.ex   # Weekly Report section
│   │   │   └── hooks/
│   │   │       └── vega_lite_hook.js       # JS hook for vega-embed rendering
│   │   └── youtrack_web.ex
│   ├── assets/
│   │   ├── js/app.js
│   │   ├── css/app.css
│   │   └── vendor/
│   ├── config/
│   │   ├── config.exs
│   │   ├── dev.exs
│   │   └── runtime.exs           # Reads same env vars as livebooks
│   ├── priv/static/
│   └── test/
├── flow_metrics.livemd           # Unchanged
├── gantt.livemd                  # Unchanged
├── pairing.livemd                # Unchanged
├── weekly_report.livemd          # Unchanged
├── workstreams.yaml              # Shared config
├── workstreams.example.yaml      # Shared config
├── prompts/                      # Shared prompts
├── docker-compose.yml            # Updated: add phoenix service
└── .env                          # Shared env vars
```

---

### Relevant files

**Reuse (no modification):**
- `youtrack/lib/youtrack/client.ex` — `new!/2`, `fetch_issues!/2`, `fetch_activities!/2`
- `youtrack/lib/youtrack/work_items.ex` — `WorkItems.build/2` (main normalization)
- `youtrack/lib/youtrack/workstreams.ex` — `streams_for_issue/3`, `parse_rules!/1`
- `youtrack/lib/youtrack/workstreams_loader.ex` — `load_from_default_paths/0`
- `youtrack/lib/youtrack/pairing_analysis.ex` — all pairing/firefighter functions
- `youtrack/lib/youtrack/rotation.ex` — rotation/tenure analysis
- `youtrack/lib/youtrack/rework.ex` — `count_by_issue/3`
- `youtrack/lib/youtrack/weekly_report.ex` — `build_issue_summary/3`
- `youtrack/lib/youtrack/card_focus.ex` — card timeline normalization, event buckets, and per-card metrics

**Reference (copy VegaLite spec logic from):**
- `flow_metrics.livemd` — 21 chart specs, data transformation logic
- `gantt.livemd` — Gantt specs, `GanttUI` classifier pattern
- `pairing.livemd` — pair matrix, firefighter specs
- `weekly_report.livemd` — report building, LLM integration

**Modify:**
- `docker-compose.yml` — add phoenix service

---

### Verification

1. `cd youtrack_web && mix deps.get && mix compile` — compiles with youtrack dep
2. `cd youtrack && mix test` — existing tests still pass (zero changes)
3. `mix phx.server` → sidebar renders, all 4 sections navigable at `localhost:4000`
4. Each section: configure credentials → "Fetch Data" → charts render matching Livebook output
5. Gantt classifier: map unclassified slug → charts re-render
6. Weekly Report: generate payload → send to LLM → response streams
7. Card Focus: open `/card/ABC-123` or search an issue key, then verify timing cards and history panels render for a known rich issue
8. `docker compose up` → both Livebook (:8080) and Phoenix (:4000) accessible
9. Open Livebooks at :8080, run top-to-bottom — still work unchanged

### Decisions

- **Standalone app** (not umbrella) — `youtrack/` stays in place, livebooks unchanged
- **VegaLite via JS hook** — same Elixir DSL, serialize to JSON, `vega-embed` renders
- **No Ecto/DB** — all data from YouTrack API
- **No auth** — localhost only
- **Single-page sidebar** — `live_patch` section switching
- **Shared config in root LiveView** — credentials entered once, available across sections

### Further Considerations

1. **VegaLite spec extraction** — The ~25 inline chart specs from `.livemd` files should be extracted into functions in `youtrack_web/` (e.g., `YoutrackWeb.Charts.FlowMetrics.throughput_by_week/1`). If Livebooks later want shared specs, promote to `youtrack/lib/youtrack/charts/`. Recommendation: keep in `youtrack_web/` for now (presentation concern).

2. **Cross-section config persistence** — Shared config (base_url, token, query) should persist across section switches via root `DashboardLive` assigns. Section-specific inputs (e.g., gantt `stream_rules`) stay local to that LiveComponent.

3. **API rate limiting** — Single shared Req client per session is sufficient for localhost use. Defer rate limiting unless it becomes an issue.

4. **Theme system exception** — The Phoenix UI now allows DaisyUI specifically as a theming mechanism for the light/dark/system selector and theme tokens. This is intentionally scoped: the app still favors bespoke Tailwind/CSS components for page structure and visual identity, while DaisyUI provides the shared theme variables and selector behavior.

5. **Config ownership boundary** — Shared form inputs live in the sidebar and are persisted via localStorage under `youtrack.shared_config`. Weekly report has additional local-only fields (report window + LLM settings) intentionally excluded from shared persistence.
