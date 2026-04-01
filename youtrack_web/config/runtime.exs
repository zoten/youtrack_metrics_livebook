import Config

dotenv_paths = [
  Path.expand("../../.env", __DIR__),
  Path.expand("../.env", __DIR__)
]

parse_env_line = fn line ->
  trimmed = String.trim(line)

  cond do
    trimmed == "" ->
      :skip

    String.starts_with?(trimmed, "#") ->
      :skip

    true ->
      normalized =
        if String.starts_with?(trimmed, "export ") do
          String.trim_leading(trimmed, "export ")
        else
          trimmed
        end

      case String.split(normalized, "=", parts: 2) do
        [key, value] ->
          env_key = String.trim(key)

          env_value =
            value
            |> String.trim()
            |> String.trim_leading("\"")
            |> String.trim_trailing("\"")
            |> String.trim_leading("'")
            |> String.trim_trailing("'")

          if env_key == "" do
            :skip
          else
            {env_key, env_value}
          end

        _ ->
          :skip
      end
  end
end

Enum.each(dotenv_paths, fn path ->
  if File.exists?(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.each(fn line ->
      case parse_env_line.(line) do
        {key, value} ->
          if is_nil(System.get_env(key)) do
            System.put_env(key, value)
          end

        :skip ->
          :ok
      end
    end)
  end
end)

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/youtrack_web start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :youtrack_web, YoutrackWeb.Endpoint, server: true
end

csv_env = fn name, default ->
  name
  |> System.get_env(default)
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
end

dashboard_defaults = %{
  "base_url" => System.get_env("YOUTRACK_BASE_URL", "https://your-instance.youtrack.cloud"),
  "token" => System.get_env("YOUTRACK_TOKEN", ""),
  "base_query" => System.get_env("YOUTRACK_BASE_QUERY", "project: MYPROJECT"),
  "days_back" => System.get_env("YOUTRACK_DAYS_BACK", "90"),
  "state_field" => System.get_env("YOUTRACK_STATE_FIELD", "State"),
  "assignees_field" => System.get_env("YOUTRACK_ASSIGNEES_FIELD", "Assignee"),
  "in_progress_names" => System.get_env("YOUTRACK_IN_PROGRESS", "In Progress"),
  "done_state_names" => System.get_env("YOUTRACK_DONE_STATES", "Done, Verified, Fixed"),
  "project_prefix" => System.get_env("YOUTRACK_PROJECT_PREFIX", ""),
  "excluded_logins" => System.get_env("YOUTRACK_EXCLUDED_LOGINS", ""),
  "use_activities" => System.get_env("YOUTRACK_USE_ACTIVITIES", "true"),
  "include_substreams" => System.get_env("YOUTRACK_INCLUDE_SUBSTREAMS", "true"),
  "unplanned_tag" => System.get_env("YOUTRACK_UNPLANNED_TAG", "on the ankles"),
  "workstreams_path" => System.get_env("WORKSTREAMS_PATH", "../workstreams.yaml"),
  "prompts_path" => System.get_env("PROMPTS_PATH", "../prompts")
}

config :youtrack_web,
  dashboard_defaults: dashboard_defaults,
  report_prompt_files: csv_env.("YOUTRACK_PROMPT_FILES", ""),
  cache_ttl_seconds: String.to_integer(System.get_env("YOUTRACK_CACHE_TTL_SECONDS", "600"))

config :youtrack_web, YoutrackWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/youtrack_web/youtrack_web.db
      """

  config :youtrack_web, YoutrackWeb.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :youtrack_web, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :youtrack_web, YoutrackWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :youtrack_web, YoutrackWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :youtrack_web, YoutrackWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :youtrack_web, YoutrackWeb.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
