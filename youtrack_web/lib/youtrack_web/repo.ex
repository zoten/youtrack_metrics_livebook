defmodule YoutrackWeb.Repo do
  use Ecto.Repo,
    otp_app: :youtrack_web,
    adapter: Ecto.Adapters.SQLite3
end
