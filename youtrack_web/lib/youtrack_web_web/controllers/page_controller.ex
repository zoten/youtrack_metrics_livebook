defmodule YoutrackWeb.PageController do
  use YoutrackWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
