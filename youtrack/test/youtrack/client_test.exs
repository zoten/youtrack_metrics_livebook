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
end
