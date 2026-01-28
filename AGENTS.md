# AGENTS.md

This repository is an **Elixir Livebook** (`.livemd`) meant to be used to gather information from YouTrack trackin system and generate insights on team behaviours.

This document defines how agents (humans and AI) should work in this repo so notebooks stay **reproducible, safe, and reviewable**.

---

## Golden rules

1. **Reproducible first**
   - A fresh clone should be able to run notebooks with minimal manual steps.
   - Prefer pinned and explicit dependencies.
   - Keep environment assumptions documented in the notebook itself.

2. **Notebooks are code**
   - Treat `.livemd` changes like application code changes: small diffs, clear intent, reviewable structure.

3. **Keep secrets out of the repo**
   - Never hardcode tokens/keys in notebooks, code, outputs, or screenshots.
   - Use `LB_*`/`LIVEBOOK_*` environment variables, `System.fetch_env!/1`, and Livebook secrets.

4. **Be kind to Git diffs**
   - Avoid noisy cell outputs and non-deterministic prints.
   - Prefer stable formatting and deterministic ordering.

---

## Repository conventions

### Notebooks layout
- Name notebooks with clear, sortable prefixes when helpful:
  - `00-intro.livemd`
  - `10-data-import.livemd`
  - `20-modeling.livemd`
- Keep each notebook focused. If it grows, split into multiple notebooks and link them.

### Supporting code
- Put reusable modules in `lib/` (or `support/`) and call them from notebooks.
- Don’t duplicate large helper functions across notebooks—extract them.
- Prefer docstrings and typespecs for helpers that multiple notebooks use.

### Testing & CI (if present)
- If notebooks depend on library code, ensure `mix test` covers that logic.
- If you validate notebooks in CI, keep notebooks deterministic and non-interactive by default.

---

## Livebook best practices

### 1) Setup section is mandatory
Each notebook should start with:
- A short purpose statement
- A **Setup** section including:
  - Elixir version expectation (if relevant)
  - Mix dependencies
  - Required env vars / secrets
  - How to obtain required datasets (or how to generate small sample data)

### 2) Dependencies
Prefer one of these approaches:

**A. Mix project in repo**
- Use `Mix.install/2` in notebooks pointing to local code when needed, or run within the repo’s Mix project context.
- Keep dependencies pinned in `mix.exs`/`mix.lock`.

**B. Notebook-local deps**
- Use `Mix.install/2` with explicit versions and minimal set of packages.
- Example pattern:
  - `Mix.install([{:req, "~> 0.5"}, {:kino, "~> 0.12"}], force: false)`
- Avoid floating versions (e.g. `">= 0.0.0"`).

### 3) Secrets and configuration
- Use Livebook Secrets for API keys and credentials where possible.
- In code, access via:
  - `System.fetch_env!/1` for required settings
  - `System.get_env/2` with defaults for optional settings
- Never print secrets (even partially).
- If a notebook needs user input, prefer `Kino.Input` and don’t persist sensitive values.

### 4) Deterministic execution
- Avoid time-based randomness unless the notebook is explicitly about it.
- When using randomness, set seeds:
  - `:rand.seed(:exsss, {1, 2, 3})` (or a documented seed)
- When enumerating maps/sets, sort for stable output.
- Avoid relying on external services without retries and clear error messages.

### 5) Keep outputs reviewable
- Prefer concise, structured outputs over huge logs.
- Large outputs:
  - Write to a file in `tmp/` or use `Kino.DataTable`, `Kino.Image`, etc.
- Do not commit massive embedded outputs in `.livemd` unless necessary.
- Avoid embedding large binaries (images, datasets) directly into notebooks.

### 6) Data handling
- Put generated/temporary data in `tmp/` and add it to `.gitignore`.
- If you need committed data:
  - Keep it small
  - Document provenance and licensing
  - Provide a script/cell to regenerate it



### 7) “Runs anywhere” guidance
- Prefer relative paths.
- If OS dependencies are needed (e.g., `pandoc`, `ffmpeg`), document installation instructions in Setup.
- If a notebook is intended for Livebook Teams / deployed Livebook:
  - Document required secrets and runtime settings explicitly.

### 8) Concurrency and long-running tasks
- Don’t spawn unmanaged processes that keep running after cells stop.
- If you start services (e.g., a local web server), provide a **Stop/Cleanup** cell.
- Use `Task` with timeouts and clear cancellation instructions where possible.

### 9) Visualization standards (Kino)
- Prefer `Kino` widgets (`Kino.DataTable`, `Kino.Mermaid`, `Kino.VegaLite`, etc.) for clarity.
- Ensure visualizations don’t depend on non-deterministic ordering.
- Label plots/tables with units and brief explanations.

---

## Contribution workflow

### Small, reviewable changes
- Keep notebook diffs small:
  - One conceptual change per PR when possible
  - Avoid re-running cells unnecessarily if it changes outputs noisily
- If you must re-run everything, mention it in the PR description.

### PR checklist (for notebooks)
- [ ] Setup section is present and complete
- [ ] Dependencies are pinned
- [ ] No secrets committed
- [ ] Notebook runs top-to-bottom on a fresh environment (or documents exceptions)
- [ ] Output is concise and stable
- [ ] Temporary files go to `tmp/` and are gitignored

---

## AI agent guidance

AI agents may propose edits to notebooks and supporting code, but must follow:

1. **No secret guessing**
   - Never invent credentials, endpoints, or internal URLs.
   - Use placeholders like `EXAMPLE_API_KEY` and document where to set it.

2. **Prefer edits over rewrites**
   - Make minimal diffs that preserve intent and history.

3. **Explain assumptions inline**
   - If a notebook assumes a dataset schema or environment, document it in the Setup section.

4. **Safety**
   - Do not add code that exfiltrates data or calls unknown external endpoints.
   - Any external network calls must be explicit, justified, and easy to disable.

5. **Performance**
   - Avoid heavy computations by default; provide a “small sample” mode and an “expanded run” mode.

---

## Patterns to copy

### Recommended notebook structure
1. Title + purpose
2. Setup
3. Inputs (params)
4. Core logic
5. Results
6. Cleanup / next steps

### Recommended configuration pattern
- `config = %{api_key: System.fetch_env!("MY_API_KEY"), base_url: System.get_env("BASE_URL", "https://example.com")}`

### Caching pattern
- Cache intermediate results to `tmp/` with a clear key (hash of inputs), and document how to invalidate.

---

## What not to do
- Don’t commit secrets.
- Don’t rely on undocumented local paths like `/Users/...`.
- Don’t leave background processes running without cleanup.
- Don’t add huge embedded outputs to `.livemd`.
- Don’t depend on “latest” package versions or unstable external resources.

---

## Ownership
- Notebook authors own maintenance of their notebooks.
- If you break a notebook, you fix it in the same PR.
