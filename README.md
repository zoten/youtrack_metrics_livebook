# Team (You)Tracker

Livebook notebooks for analyzing team activity from YouTrack. Visualize work timelines, pairing patterns, and unplanned work distribution.

## Features

### Gantt Chart (`gantt.livemd`)
- **Timeline visualization** of issues by assignee and workstream
- **Unplanned work analysis** with visual distinction (orangered vs steelblue)
- **Metrics** showing % unplanned work per person and per stream
- **Interrupt heatmaps** by day of week and day of month
- **Interactive classifier** for mapping unknown issue slugs to workstreams

### Pairing Patterns (`pairing.livemd`)
- **Pair matrix heatmap** showing collaboration frequency
- **Pairing trends** over time
- **Firefighter detection** — identifies who handles the most interrupt work
- **Interrupt frequency charts** (aggregate and per-person)

## Prerequisites

- Docker and Docker Compose
- YouTrack permanent token ([how to create](https://www.jetbrains.com/help/youtrack/server/Manage-Permanent-Token.html))

## Quick Start

```bash
# 1. Clone the repository
git clone <repo-url>
cd youtrack

# 2. Copy and configure environment
cp .env.example .env
# Edit .env with your YouTrack URL and token

# 3. Configure workstreams (optional but recommended)
cp workstreams.example.yaml workstreams.yaml
# Edit workstreams.yaml to match your project's workstreams

# 4. Start Livebook
docker compose up
# docker compose up -d

# 5. Open http://localhost:8080 in your browser
```

## Configuration

### Environment Variables (`.env`)

| Variable | Required | Description |
|----------|----------|-------------|
| `YOUTRACK_BASE_URL` | Yes | Your YouTrack instance URL |
| `YOUTRACK_TOKEN` | Yes | Permanent API token |
| `YOUTRACK_BASE_QUERY` | No | Base query filter (e.g., `project: MYPROJECT`) |
| `YOUTRACK_DAYS_BACK` | No | Days of history to fetch (default: 90) |
| `YOUTRACK_PROJECT_PREFIX` | No | Filter issues by ID prefix |
| `YOUTRACK_STATE_FIELD` | No | Custom state field name (default: `State`) |
| `YOUTRACK_ASSIGNEES_FIELD` | No | Custom assignees field name (default: `Assignee`) |
| `YOUTRACK_IN_PROGRESS` | No | Comma-separated "in progress" state names |
| `YOUTRACK_EXCLUDED_LOGINS` | No | Comma-separated logins to exclude |
| `YOUTRACK_UNPLANNED_TAG` | No | Tag for unplanned work (default: `on the ankles`) |

### Workstreams (`workstreams.yaml`)

Map issues to workstreams by summary prefix (slug) or tag:

```yaml
BACKEND:
  slugs:
    - BACKEND       # Matches "[BACKEND] Fix something"
  tags:
    - team:backend  # Matches issues tagged "team:backend"

API:
  slugs:
    - API
  substream_of:
    - BACKEND       # API issues also count toward BACKEND
```

- **slugs**: Match issue summaries starting with `[SLUG]`
- **tags**: Match YouTrack tags
- **substream_of**: Parent workstreams (for hierarchical rollup)

## Usage

1. **Start Livebook**: `docker compose up`
2. **Open** http://localhost:8080
3. **Select a notebook** (`gantt.livemd` or `pairing.livemd`)
4. **Run cells** top-to-bottom (or use "Evaluate all")
5. **Adjust inputs** as needed and re-run the filter/analysis cells

### Tips

- The "Fetch Issues" cell makes API calls — only re-run when you need fresh data
- Use "Filter & Process" to iterate on filtering without hitting the API
- The interactive classifier in `gantt.livemd` helps map unrecognized slugs
- Mark interrupt work with your configured tag (default: `on the ankles`) to see unplanned work metrics

## Development

The notebooks use a local Mix project (`youtrack/`) for shared modules:

```bash
cd youtrack
mix deps.get
mix test
```

## Stopping

```bash
docker compose down
```

## License

MIT