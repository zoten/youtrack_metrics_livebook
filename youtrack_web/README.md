# Youtrack

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Docker Production Run

The repository root includes a `docker-compose.yml` that runs Livebook and this Phoenix app side by side.

1. Set `SECRET_KEY_BASE` in `.env`.
2. From repository root, run `docker compose up --build phoenix`.
3. Open `http://localhost:4000`.

The `phoenix` service:

- builds a release via a multi-stage Dockerfile
- runs migrations at container startup using `YoutrackWeb.Release.migrate`
- reads shared inputs from mounted paths:
	- `WORKSTREAMS_PATH=/data/workstreams.yaml`
	- `PROMPTS_PATH=/data/prompts`

## Configuration Model

- Shared YouTrack configuration is edited from the sidebar form (`sidebar-shared-config-form`) and is reused across all LiveView pages.
- Shared fields are persisted in browser localStorage (`youtrack.shared_config`) and sent as LiveView connect params on navigation/reconnect.
- Weekly report keeps report/LLM fields local to the weekly page form (`weekly-config-form`), so those values do not leak into other pages.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
