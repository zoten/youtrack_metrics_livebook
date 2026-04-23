defmodule YoutrackWeb.CardTimelineFiltersPreference do
  @moduledoc false

  @default %{
    exclude_todo?: false,
    exclude_no_sprint?: false
  }

  def from_socket(socket) do
    socket
    |> maybe_connect_params()
    |> Map.get("card_timeline_filters")
    |> normalize_payload()
  end

  defp normalize_payload(payload) when is_map(payload) do
    %{
      exclude_todo?: normalize_bool(Map.get(payload, "exclude_todo")),
      exclude_no_sprint?: normalize_bool(Map.get(payload, "exclude_no_sprint"))
    }
  end

  defp normalize_payload(_), do: @default

  defp normalize_bool(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp normalize_bool(_), do: false

  defp maybe_connect_params(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.LiveView.get_connect_params(socket) || %{}
    else
      %{}
    end
  end
end
