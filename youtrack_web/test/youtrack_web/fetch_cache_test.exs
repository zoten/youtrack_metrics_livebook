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
    assert first_state == :miss
    assert second_state == :hit
  end

  test "refresh option bypasses cache" do
    {:ok, _value, :miss} =
      FetchCache.get_or_fetch(:refresh_key, fn -> "old" end, ttl_ms: 60_000)

    {:ok, refreshed, refreshed_state} =
      FetchCache.get_or_fetch(:refresh_key, fn -> "new" end, ttl_ms: 60_000, refresh: true)

    assert refreshed == "new"
    assert refreshed_state == :refresh
  end
end
