defmodule YoutrackWeb.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias YoutrackWeb.RuntimeConfig
  alias YoutrackWeb.RuntimeConfig.Server

  test "reads snapshot values through the public ETS-backed API" do
    snapshot = snapshot_fixture(%{cache_ttl_seconds: 42})

    server =
      start_supervised!(
        {Server, loader: fn -> {:ok, snapshot} end, pubsub: nil, broadcast?: false}
      )

    assert RuntimeConfig.dashboard_defaults(server: server)["base_url"] == "https://example.test"
    assert RuntimeConfig.cache_ttl_seconds(server: server) == 42
    assert RuntimeConfig.report_prompt_files(server: server) == ["summary.md"]
    assert RuntimeConfig.workstreams_path(server: server) == "../workstreams.yaml"
    assert RuntimeConfig.fetch(:missing_key, server: server) == :error
  end

  test "reload swaps the snapshot and increments the metadata version" do
    snapshots =
      start_supervised!(
        {Agent,
         fn ->
           [
             snapshot_fixture(%{cache_ttl_seconds: 10}),
             snapshot_fixture(%{cache_ttl_seconds: 90})
           ]
         end}
      )

    loader = fn ->
      Agent.get_and_update(snapshots, fn
        [next | rest] -> {{:ok, next}, rest}
        [] -> {{:error, "no more snapshots"}, []}
      end)
    end

    server = start_supervised!({Server, loader: loader, pubsub: nil, broadcast?: false})

    initial = RuntimeConfig.snapshot(server: server)
    assert initial.cache_ttl_seconds == 10
    assert initial.metadata.version == 1

    assert {:ok, reloaded} = RuntimeConfig.reload(server: server, reason: :manual)
    assert reloaded.cache_ttl_seconds == 90
    assert reloaded.metadata.version == 2
    assert reloaded.metadata.reason == :manual
    assert RuntimeConfig.cache_ttl_seconds(server: server) == 90
  end

  test "put and update serialize writes through the server" do
    server =
      start_supervised!(
        {Server, loader: fn -> {:ok, snapshot_fixture()} end, pubsub: nil, broadcast?: false}
      )

    assert :ok = RuntimeConfig.put(:cache_ttl_seconds, 15, server: server)
    assert RuntimeConfig.cache_ttl_seconds(server: server) == 15

    assert {:ok, snapshot} =
             RuntimeConfig.update(
               fn current ->
                 Map.update!(
                   current,
                   :dashboard_defaults,
                   &Map.put(&1, "base_query", "project: NEXT")
                 )
               end,
               server: server,
               reason: :test_update
             )

    assert snapshot.dashboard_defaults["base_query"] == "project: NEXT"
    assert snapshot.metadata.reason == :test_update
    assert snapshot.metadata.version == 3
  end

  defp snapshot_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        dashboard_defaults: %{
          "base_url" => "https://example.test",
          "token" => "secret-token",
          "base_query" => "project: TEST",
          "days_back" => "30",
          "workstreams_path" => "../workstreams.yaml",
          "prompts_path" => "../prompts"
        },
        cache_ttl_seconds: 60,
        report_prompt_files: ["summary.md"],
        workstream_rules: %{fallback: ["(unclassified)"]},
        workstreams_path: "../workstreams.yaml"
      },
      overrides
    )
  end
end
