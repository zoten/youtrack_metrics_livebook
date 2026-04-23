defmodule YoutrackWeb.Charts.CardFocus do
  @moduledoc """
  Card Focus chart specification builders.
  """

  def state_timeline_spec(card_data) do
    state_values =
      card_data.state_segments
      |> Enum.map(fn segment ->
        %{
          track: "State",
          label: segment.state,
          sprint: sprint_label(segment),
          start: to_iso8601(segment.start_ms),
          end: to_iso8601(segment.end_ms),
          duration_hours: Float.round(segment.duration_ms / 3_600_000, 2)
        }
      end)

    unique_states =
      card_data.state_segments
      |> Enum.map(& &1.state)
      |> Enum.uniq()

    state_color_map_result = state_color_map(unique_states)

    activity_values =
      card_data.active_segments
      |> Enum.map(fn segment ->
        %{
          track: "Activity",
          label: segment.label,
          sprint: "N/A",
          start: to_iso8601(segment.start_ms),
          end: to_iso8601(segment.end_ms),
          duration_hours: Float.round(segment.duration_ms / 3_600_000, 2)
        }
      end)

    activity_domain = activity_values |> Enum.map(& &1.label) |> Enum.uniq() |> Enum.sort()

    activity_palette = %{
      "Active" => "#10b981",
      "Inactive" => "#94a3b8",
      "On Hold" => "#ef4444"
    }

    activity_range = Enum.map(activity_domain, &Map.get(activity_palette, &1, "#cccccc"))

    shared_tooltip = [
      %{"field" => "label", "type" => "nominal", "title" => "Label"},
      %{"field" => "sprint", "type" => "nominal", "title" => "Sprint"},
      %{"field" => "start", "type" => "temporal", "title" => "Start", "format" => "%b %d %H:%M"},
      %{"field" => "end", "type" => "temporal", "title" => "End", "format" => "%b %d %H:%M"},
      %{"field" => "duration_hours", "type" => "quantitative", "title" => "Duration (h)"}
    ]

    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "height" => 160,
      "layer" => [
        %{
          "data" => %{"values" => state_values},
          "mark" => %{"type" => "bar", "cornerRadius" => 3, "height" => %{"band" => 0.75}},
          "encoding" => %{
            "y" => %{"field" => "track", "type" => "nominal", "axis" => %{"title" => ""}},
            "x" => %{"field" => "start", "type" => "temporal", "title" => "Timeline"},
            "x2" => %{"field" => "end"},
            "color" => %{
              "field" => "label",
              "type" => "nominal",
              "scale" => %{
                "domain" => unique_states,
                "range" => Enum.map(unique_states, &state_color_map_result[&1])
              },
              "legend" => %{"title" => "State"}
            },
            "tooltip" => shared_tooltip
          }
        },
        %{
          "data" => %{"values" => activity_values},
          "mark" => %{"type" => "bar", "cornerRadius" => 3, "height" => %{"band" => 0.75}},
          "encoding" => %{
            "y" => %{"field" => "track", "type" => "nominal", "axis" => %{"title" => ""}},
            "x" => %{"field" => "start", "type" => "temporal", "title" => "Timeline"},
            "x2" => %{"field" => "end"},
            "color" => %{
              "field" => "label",
              "type" => "nominal",
              "scale" => %{
                "domain" => activity_domain,
                "range" => activity_range
              },
              "legend" => %{"title" => "Activity"}
            },
            "tooltip" => shared_tooltip
          }
        }
      ],
      "resolve" => %{"scale" => %{"color" => "independent"}}
    }
  end

  defp state_color_map(states) do
    color_palette = %{
      "In Progress" => "#3b82f6",
      "Review" => "#8b5cf6",
      "Testing" => "#ec4899",
      "Done" => "#10b981",
      "Backlog" => "#6b7280",
      "To Do" => "#f59e0b",
      "Open" => "#06b6d4",
      "Closed" => "#6366f1",
      "In Review" => "#a855f7",
      "QA" => "#f43f5e",
      "Staging" => "#14b8a6",
      "Production" => "#22c55e"
    }

    generated_colors = [
      "#0ea5e9",
      "#06b6d4",
      "#10b981",
      "#84cc16",
      "#eab308",
      "#f59e0b",
      "#f97316",
      "#ef4444",
      "#e11d48",
      "#9333ea"
    ]

    Enum.reduce(states, {%{}, 0}, fn state, {acc, color_idx} ->
      color =
        if Map.has_key?(color_palette, state) do
          color_palette[state]
        else
          idx = rem(color_idx, length(generated_colors))
          Enum.at(generated_colors, idx)
        end

      {Map.put(acc, state, color), color_idx + 1}
    end)
    |> elem(0)
  end

  defp to_iso8601(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp to_iso8601(timestamp_ms) do
    timestamp_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp sprint_label(segment) do
    sprint_names = Map.get(segment, :sprint_names, [])

    if sprint_names == [] do
      "No sprint"
    else
      Enum.join(sprint_names, ", ")
    end
  end
end
