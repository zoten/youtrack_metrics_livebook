defmodule YoutrackWeb.FetchCache do
  @moduledoc """
  Small ETS-backed cache for expensive YouTrack fetch calls.
  """

  use GenServer

  @table :youtrack_web_fetch_cache

  def start_link(_opts) do
    GenServer.start_link(YoutrackWeb.FetchCache, %{}, name: YoutrackWeb.FetchCache)
  end

  @impl true
  def init(_state) do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        :ok
    end

    {:ok, %{}}
  end

  def get_or_fetch(key, fetch_fun, opts \\ []) when is_function(fetch_fun, 0) do
    refresh? = Keyword.get(opts, :refresh, false)
    ttl_ms = Keyword.get(opts, :ttl_ms, ttl_from_config_ms())
    now = System.system_time(:millisecond)

    if refresh? do
      fetch_and_store(key, fetch_fun, now, ttl_ms, :refresh)
    else
      case :ets.lookup(@table, key) do
        [{^key, expires_at, fetched_at, value}] when expires_at > now ->
          {:ok, value, %{source: :hit, fetched_at_ms: fetched_at, expires_at_ms: expires_at}}

        [{^key, expires_at, value}] when expires_at > now ->
          {:ok, value, %{source: :hit, fetched_at_ms: now, expires_at_ms: expires_at}}

        _ ->
          fetch_and_store(key, fetch_fun, now, ttl_ms, :miss)
      end
    end
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp fetch_and_store(key, fetch_fun, now, ttl_ms, cache_state) do
    value = fetch_fun.()
    expires_at = now + ttl_ms
    :ets.insert(@table, {key, expires_at, now, value})
    {:ok, value, %{source: cache_state, fetched_at_ms: now, expires_at_ms: expires_at}}
  end

  defp ttl_from_config_ms do
    seconds = Application.get_env(:youtrack_web, :cache_ttl_seconds, 600)
    seconds * 1000
  end
end
