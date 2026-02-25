defmodule Youtrack.ClientTest do
  use ExUnit.Case, async: true

  alias Youtrack.Client

  describe "new!/2" do
    test "creates a Req client with correct headers" do
      client = Client.new!("https://example.youtrack.cloud", "my-token")

      assert %Req.Request{} = client
      headers = client.headers

      # Check authorization header (Req stores header values as lists)
      auth_header = Enum.find(headers, fn {k, _} -> k == "authorization" end)
      assert {"authorization", ["Bearer my-token"]} = auth_header

      # Check accept header
      accept_header = Enum.find(headers, fn {k, _} -> k == "accept" end)
      assert {"accept", ["application/json"]} = accept_header
    end

    test "strips trailing slash from base URL" do
      client = Client.new!("https://example.youtrack.cloud/", "my-token")

      # The base_url should not have a trailing slash
      assert client.options.base_url == "https://example.youtrack.cloud"
    end
  end

  describe "fetch_issues!/2" do
    test "returns issues from a single page" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([%{"id" => "1", "summary" => "Test"}]))
      end

      req = Req.new(plug: plug)
      issues = Client.fetch_issues!(req, "project: TEST")

      assert [%{"id" => "1", "summary" => "Test"}] = issues
    end

    test "paginates through multiple pages" do
      call_count = :counters.new(1, [:atomics])

      plug = fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        body =
          case count do
            1 ->
              # Return exactly :top items (default 100) to trigger next page
              Enum.map(1..100, fn i -> %{"id" => "#{i}"} end) |> Jason.encode!()

            2 ->
              # Return fewer than :top to signal last page
              [%{"id" => "101"}] |> Jason.encode!()
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      req = Req.new(plug: plug)
      issues = Client.fetch_issues!(req, "project: TEST")

      assert length(issues) == 101
      assert :counters.get(call_count, 1) == 2
    end

    test "returns empty list when API returns no issues" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "[]")
      end

      req = Req.new(plug: plug)
      assert [] == Client.fetch_issues!(req, "project: TEST")
    end

    test "raises on non-200 status" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "Unauthorized"}))
      end

      req = Req.new(plug: plug)

      assert_raise RuntimeError, ~r/YouTrack API returned status 401/, fn ->
        Client.fetch_issues!(req, "project: TEST")
      end
    end

    test "raises on non-list response body" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"error" => "bad query"}))
      end

      req = Req.new(plug: plug)

      assert_raise RuntimeError, ~r/Expected list of issues/, fn ->
        Client.fetch_issues!(req, "bad query")
      end
    end
  end

  describe "fetch_activities!/2" do
    test "returns activities for an issue" do
      plug = fn conn ->
        assert conn.request_path =~ "/api/issues/issue-1/activities"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!([
            %{"timestamp" => 1_700_000_000_000, "field" => %{"name" => "State"}}
          ])
        )
      end

      req = Req.new(plug: plug)
      activities = Client.fetch_activities!(req, "issue-1")

      assert [%{"timestamp" => 1_700_000_000_000}] = activities
    end

    test "raises on non-200 status" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "Not found"}))
      end

      req = Req.new(plug: plug)

      assert_raise RuntimeError, ~r/YouTrack API returned status 404/, fn ->
        Client.fetch_activities!(req, "missing-id")
      end
    end
  end
end
