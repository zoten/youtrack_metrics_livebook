defmodule YoutrackWeb.Charts.Comparison do
  @moduledoc """
  Chart specification builders for multi-card comparison views.
  """

  @activity_palette %{
    "Active" => "#10b981",
    "Inactive" => "#94a3b8",
    "On Hold" => "#ef4444"
  }

  @state_palette %{
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

  @fallback_colors [
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

  def shared_timeline_spec(cards) when is_list(cards) do
    state_values = Enum.flat_map(cards, &state_values_for_card/1)
    activity_values = Enum.flat_map(cards, &activity_values_for_card/1)

    state_domain = state_values |> Enum.map(& &1["label"]) |> Enum.uniq()
    activity_domain = activity_values |> Enum.map(& &1["label"]) |> Enum.uniq() |> Enum.sort()

    state_color_map = state_color_map(state_domain)

    values = state_values ++ activity_values

    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "data" => %{"values" => values},
      "facet" => %{
        "row" => %{
          "field" => "issue_key",
          "type" => "nominal",
          "sort" => %{"field" => "issue_order", "op" => "min", "order" => "ascending"},
          "header" => %{"title" => nil, "labelFontSize" => 13, "labelPadding" => 8}
        }
      },
      "spec" => %{
        "width" => "container",
        "height" => 74,
        "layer" => [
          state_layer(state_domain, state_color_map),
          activity_layer(activity_domain)
        ],
        "resolve" => %{"scale" => %{"color" => "independent"}}
      }
    }
  end

  def state_events_timeline_spec(cards) when is_list(cards) do
    values = Enum.flat_map(cards, &state_event_values_for_card/1)

    faceted_point_timeline_spec(values,
      color: "#3b82f6",
      title: "State change",
      tooltip: state_event_tooltip(),
      point_size: 90,
      point_shape: "diamond"
    )
  end

  def comment_timeline_spec(cards) when is_list(cards) do
    values = Enum.flat_map(cards, &comment_event_values_for_card/1)

    faceted_point_timeline_spec(values,
      color: "#f59e0b",
      title: "Comment",
      tooltip: comment_tooltip(),
      point_size: 80,
      point_shape: "circle"
    )
  end

  def tag_timeline_spec(cards) when is_list(cards) do
    values = Enum.flat_map(cards, &tag_event_values_for_card/1)

    faceted_point_timeline_spec(values,
      color_field: "change_type",
      color_domain: ["added", "removed", "mixed"],
      color_range: ["#10b981", "#ef4444", "#8b5cf6"],
      title: "Tag change",
      tooltip: tag_tooltip(),
      point_size: 85,
      point_shape: "square"
    )
  end

  defp state_layer(state_domain, state_color_map) do
    %{
      "transform" => [%{"filter" => "datum.track === 'State'"}],
      "mark" => %{"type" => "bar", "cornerRadius" => 3, "height" => %{"band" => 0.75}},
      "encoding" => %{
        "y" => %{"field" => "track", "type" => "nominal", "axis" => %{"title" => nil}},
        "x" => %{"field" => "start", "type" => "temporal", "title" => "Timeline"},
        "x2" => %{"field" => "end"},
        "color" => %{
          "field" => "label",
          "type" => "nominal",
          "scale" => %{
            "domain" => state_domain,
            "range" => Enum.map(state_domain, &state_color_map[&1])
          },
          "legend" => %{"title" => "State"}
        },
        "tooltip" => shared_tooltip()
      }
    }
  end

  defp activity_layer(activity_domain) do
    %{
      "transform" => [%{"filter" => "datum.track === 'Activity'"}],
      "mark" => %{"type" => "bar", "cornerRadius" => 3, "height" => %{"band" => 0.75}},
      "encoding" => %{
        "y" => %{"field" => "track", "type" => "nominal", "axis" => %{"title" => nil}},
        "x" => %{"field" => "start", "type" => "temporal", "title" => "Timeline"},
        "x2" => %{"field" => "end"},
        "color" => %{
          "field" => "label",
          "type" => "nominal",
          "scale" => %{
            "domain" => activity_domain,
            "range" => Enum.map(activity_domain, &Map.get(@activity_palette, &1, "#cccccc"))
          },
          "legend" => %{"title" => "Activity"}
        },
        "tooltip" => shared_tooltip()
      }
    }
  end

  defp shared_tooltip do
    [
      %{"field" => "issue_key", "type" => "nominal", "title" => "Issue"},
      %{"field" => "label", "type" => "nominal", "title" => "Label"},
      %{"field" => "start", "type" => "temporal", "title" => "Start", "format" => "%b %d %H:%M"},
      %{"field" => "end", "type" => "temporal", "title" => "End", "format" => "%b %d %H:%M"},
      %{"field" => "duration_hours", "type" => "quantitative", "title" => "Duration (h)"}
    ]
  end

  defp state_event_tooltip do
    [
      %{"field" => "issue_key", "type" => "nominal", "title" => "Issue"},
      %{"field" => "transition", "type" => "nominal", "title" => "Transition"},
      %{"field" => "author", "type" => "nominal", "title" => "Author"},
      %{
        "field" => "timestamp",
        "type" => "temporal",
        "title" => "Time",
        "format" => "%b %d %H:%M"
      }
    ]
  end

  defp comment_tooltip do
    [
      %{"field" => "issue_key", "type" => "nominal", "title" => "Issue"},
      %{"field" => "author", "type" => "nominal", "title" => "Author"},
      %{"field" => "excerpt", "type" => "nominal", "title" => "Comment"},
      %{
        "field" => "timestamp",
        "type" => "temporal",
        "title" => "Time",
        "format" => "%b %d %H:%M"
      }
    ]
  end

  defp tag_tooltip do
    [
      %{"field" => "issue_key", "type" => "nominal", "title" => "Issue"},
      %{"field" => "tag_summary", "type" => "nominal", "title" => "Change"},
      %{"field" => "author", "type" => "nominal", "title" => "Author"},
      %{
        "field" => "timestamp",
        "type" => "temporal",
        "title" => "Time",
        "format" => "%b %d %H:%M"
      }
    ]
  end

  defp faceted_point_timeline_spec(values, opts) do
    spec_encoding = %{
      "x" => %{"field" => "timestamp", "type" => "temporal", "title" => "Timeline"},
      "y" => %{
        "field" => "lane",
        "type" => "nominal",
        "axis" => %{"title" => nil, "labels" => false, "ticks" => false, "domain" => false}
      },
      "tooltip" => Keyword.fetch!(opts, :tooltip)
    }

    color_encoding =
      cond do
        Keyword.has_key?(opts, :color_field) ->
          %{
            "color" => %{
              "field" => Keyword.fetch!(opts, :color_field),
              "type" => "nominal",
              "scale" => %{
                "domain" => Keyword.fetch!(opts, :color_domain),
                "range" => Keyword.fetch!(opts, :color_range)
              },
              "legend" => %{"title" => Keyword.fetch!(opts, :title)}
            }
          }

        true ->
          %{"color" => %{"value" => Keyword.fetch!(opts, :color)}}
      end

    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "data" => %{"values" => values},
      "facet" => %{
        "row" => %{
          "field" => "issue_key",
          "type" => "nominal",
          "sort" => %{"field" => "issue_order", "op" => "min", "order" => "ascending"},
          "header" => %{"title" => nil, "labelFontSize" => 13, "labelPadding" => 8}
        }
      },
      "spec" => %{
        "width" => "container",
        "height" => 36,
        "mark" => %{
          "type" => "point",
          "filled" => true,
          "size" => Keyword.get(opts, :point_size, 80),
          "shape" => Keyword.get(opts, :point_shape, "circle")
        },
        "encoding" => Map.merge(spec_encoding, color_encoding)
      }
    }
  end

  defp state_values_for_card(%{
         issue_id: issue_id,
         issue_order: issue_order,
         card_data: card_data
       }) do
    issue_key = issue_key(card_data, issue_id)

    Enum.map(card_data.state_segments, fn segment ->
      %{
        "issue_id" => issue_id,
        "issue_key" => issue_key,
        "issue_order" => issue_order,
        "track" => "State",
        "label" => segment.state,
        "start" => to_iso8601(segment.start_ms),
        "end" => to_iso8601(segment.end_ms),
        "duration_hours" => to_duration_hours(segment.duration_ms)
      }
    end)
  end

  defp activity_values_for_card(%{
         issue_id: issue_id,
         issue_order: issue_order,
         card_data: card_data
       }) do
    issue_key = issue_key(card_data, issue_id)

    Enum.map(card_data.active_segments, fn segment ->
      %{
        "issue_id" => issue_id,
        "issue_key" => issue_key,
        "issue_order" => issue_order,
        "track" => "Activity",
        "label" => segment.label,
        "start" => to_iso8601(segment.start_ms),
        "end" => to_iso8601(segment.end_ms),
        "duration_hours" => to_duration_hours(segment.duration_ms)
      }
    end)
  end

  defp state_event_values_for_card(%{
         issue_id: issue_id,
         issue_order: issue_order,
         card_data: card_data
       }) do
    issue_key = issue_key(card_data, issue_id)

    Enum.map(card_data.state_events, fn event ->
      %{
        "issue_id" => issue_id,
        "issue_key" => issue_key,
        "issue_order" => issue_order,
        "lane" => "State",
        "timestamp" => to_iso8601(event.timestamp),
        "transition" => "#{event_value(event.from)} -> #{event_value(event.to)}",
        "author" => event.author || "Unknown"
      }
    end)
  end

  defp comment_event_values_for_card(%{
         issue_id: issue_id,
         issue_order: issue_order,
         card_data: card_data
       }) do
    issue_key = issue_key(card_data, issue_id)

    Enum.map(card_data.comment_events, fn event ->
      %{
        "issue_id" => issue_id,
        "issue_key" => issue_key,
        "issue_order" => issue_order,
        "lane" => "Comments",
        "timestamp" => to_iso8601(event.timestamp),
        "author" => event.author || "Unknown",
        "excerpt" => truncate_text(event.text)
      }
    end)
  end

  defp tag_event_values_for_card(%{
         issue_id: issue_id,
         issue_order: issue_order,
         card_data: card_data
       }) do
    issue_key = issue_key(card_data, issue_id)

    Enum.map(card_data.tag_events, fn event ->
      %{
        "issue_id" => issue_id,
        "issue_key" => issue_key,
        "issue_order" => issue_order,
        "lane" => "Tags",
        "timestamp" => to_iso8601(event.timestamp),
        "author" => event.author || "Unknown",
        "tag_summary" => "+ #{event_value(event.added)} / - #{event_value(event.removed)}",
        "change_type" => tag_change_type(event)
      }
    end)
  end

  defp issue_key(card_data, issue_id) do
    get_in(card_data, [:issue, :issue_key]) || issue_id
  end

  defp event_value([]), do: "No value"
  defp event_value(values) when is_list(values), do: Enum.join(values, ", ")
  defp event_value(value) when is_binary(value), do: value
  defp event_value(_), do: "No value"

  defp tag_change_type(event) do
    cond do
      event.added != [] and event.removed != [] -> "mixed"
      event.added != [] -> "added"
      true -> "removed"
    end
  end

  defp truncate_text(nil), do: ""

  defp truncate_text(text) do
    if String.length(text) > 90 do
      String.slice(text, 0, 87) <> "..."
    else
      text
    end
  end

  defp to_duration_hours(duration_ms) when is_number(duration_ms) do
    Float.round(duration_ms / 3_600_000, 2)
  end

  defp to_duration_hours(_), do: 0.0

  defp state_color_map(states) do
    Enum.reduce(states, {%{}, 0}, fn state, {acc, color_idx} ->
      color =
        if Map.has_key?(@state_palette, state) do
          @state_palette[state]
        else
          idx = rem(color_idx, length(@fallback_colors))
          Enum.at(@fallback_colors, idx)
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
end
