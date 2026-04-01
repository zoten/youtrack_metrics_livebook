defmodule YoutrackWeb.FetchCacheTest do
  use ExUnit.Case, async: false

  alias YoutrackWeb.FetchCache

  setup do
    FetchCache.clear()
    :ok
  end

  test "returns cache hit for repeated key" do
    {:ok, first, first_state} =
      FetchCache.get_or_fetch(:sample_key, fn -> "value-1" end, ttl_ms: 60_000)

    {:ok, second, second_state} =
      FetchCache.get_or_fetch(:sample_key, fn -> "value-2" end, ttl_ms: 60_000)

    assert first == "value-1"
    assert second == "value-1"
    assert first_state.source == :miss
    assert is_integer(first_state.fetched_at_ms)
    assert second_state.source == :hit
    assert is_integer(second_state.fetched_at_ms)
  end

  test "refresh option bypasses cache" do
    {:ok, _value, initial_state} =
      FetchCache.get_or_fetch(:refresh_key, fn -> "old" end, ttl_ms: 60_000)

    assert initial_state.source == :miss

    {:ok, refreshed, refreshed_state} =
      FetchCache.get_or_fetch(:refresh_key, fn -> "new" end, ttl_ms: 60_000, refresh: true)

    assert refreshed == "new"
    assert refreshed_state.source == :refresh
    assert is_integer(refreshed_state.fetched_at_ms)
  end
end
