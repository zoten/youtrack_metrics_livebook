defmodule YoutrackWeb.ConfigVisibilityPreference do
  @moduledoc false

  @default true

  def from_socket(socket) do
    socket
    |> maybe_connect_params()
    |> Map.get("config_open")
    |> normalize()
  end

  def normalize(true), do: true
  def normalize(false), do: false
  def normalize("true"), do: true
  def normalize("false"), do: false
  def normalize(_), do: @default

  defp maybe_connect_params(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.LiveView.get_connect_params(socket) || %{}
    else
      %{}
    end
  end
end
