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

### Weekly Delivery Report (`weekly_report.livemd`)
- **Last working day report** and **last week report** in one run
- **LLM-ready JSON payload** for product and engineering lead summaries
- **Cycle time starts** at transition from inactive/no-state to active work
- **Net active time** excludes periods tagged as hold/blocked
- **Selectable prompt source** from `prompts/`, backward-compatible `.prompt`, or manual input

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

# First run downloads Livebook/Mix dependencies into Docker volumes.
# Later container recreations reuse that cache automatically.

# 5. Open http://localhost:8080 in your browser
```

## Configuration

### Environment Variables (`.env`)

| Variable                          | Required | Description                                                                        |
| --------------------------------- | -------- | ---------------------------------------------------------------------------------- |
| `YOUTRACK_BASE_URL`               | Yes      | Your YouTrack instance URL                                                         |
| `YOUTRACK_TOKEN`                  | Yes      | Permanent API token                                                                |
| `YOUTRACK_BASE_QUERY`             | No       | Base query filter (e.g., `project: MYPROJECT`)                                     |
| `YOUTRACK_DAYS_BACK`              | No       | Days of history to fetch (default: 90)                                             |
| `YOUTRACK_PROJECT_PREFIX`         | No       | Filter issues by ID prefix                                                         |
| `YOUTRACK_STATE_FIELD`            | No       | Custom state field name (default: `State`)                                         |
| `YOUTRACK_ASSIGNEES_FIELD`        | No       | Custom assignees field name (default: `Assignee`)                                  |
| `YOUTRACK_IN_PROGRESS`            | No       | Comma-separated "in progress" state names                                          |
| `YOUTRACK_REPORT_INACTIVE_STATES` | No       | Comma-separated inactive states used for cycle-time start (default: `To Do, Todo`) |
| `YOUTRACK_EXCLUDED_LOGINS`        | No       | Comma-separated logins to exclude                                                  |
| `YOUTRACK_UNPLANNED_TAG`          | No       | Tag for unplanned work (default: `unplanned`)                                      |

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

### Local LLM Integration

The `## Run with Local LLM` section at the end of the notebook sends the report payload to any OpenAI-compatible backend:

- **[Ollama](https://ollama.com)** — simplest setup; run `ollama serve` and `ollama pull <model>`
- **LM Studio** — GUI, exposes `/v1` on `http://localhost:1234` by default
- **llama.cpp** server — `llama-server --model <path> --port 8080`

#### Model sizing guide

| Hardware         | Model              | Ollama tag                    |
| ---------------- | ------------------ | ----------------------------- |
| CPU / ≤8 GB RAM  | Llama 3.2 3B       | `llama3.2:3b`                 |
| CPU / ≤16 GB RAM | Qwen2.5 7B Q4      | `qwen2.5:7b`                  |
| CPU / ≥16 GB RAM | Phi-4 14B Q4       | `phi4:14b-q4_K_M`             |
| GPU ≥16 GB VRAM  | Qwen2.5 32B Q4     | `qwen2.5:32b-instruct-q4_K_M` |
| GPU ≥20 GB VRAM  | DeepSeek-R1 32B Q4 | `deepseek-r1:32b-q4_K_M`      |

Set `LLM_BASE_URL` and `LLM_MODEL` env vars to pre-fill the notebook inputs.

### Weekly Prompt Template Configuration

The weekly report notebook lets you choose the LLM prompt source before generating the final prompt:

1. Add local prompt templates under `prompts/`, or keep using the backward-compatible root `.prompt`
2. Pick a discovered file from the notebook dropdown, or switch to manual prompt input
3. Keep `{{REPORT_PAYLOAD_JSON}}` in the template if you want inline substitution
4. If the placeholder is missing, the JSON payload is appended automatically at the end
5. Everything under `prompts/` is gitignored except `prompts/.gitkeep`, so local prompt variants stay out of the repo

This keeps prompt text easy to iterate on locally while preserving a simple root `.prompt` fallback.

### Tips

- The "Fetch Issues" cell makes API calls — only re-run when you need fresh data
- Use "Filter & Process" to iterate on filtering without hitting the API
- The interactive classifier in `gantt.livemd` helps map unrecognized slugs
- Mark interrupt work with your configured tag (default: `unplanned`) to see unplanned work metrics

## Development

The notebooks use a local Mix project (`youtrack/`) for shared modules:

```bash
cd youtrack
mix deps.get
mix test
```

## Docker Dependency Cache

The Livebook service persists these directories as Docker named volumes:

- `/home/livebook/.mix`
- `/home/livebook/.hex`
- `/home/livebook/.cache`

That means Hex packages, Mix metadata, and compiled dependency cache survive `docker compose down` and later `docker compose up` runs.

Use the default stop command to keep the cache:

```bash
docker compose down
```

Remove the volumes only when you want a cold start and dependency re-download:

```bash
docker compose down -v
```

## Stopping

```bash
docker compose down
```

## License

MIT
