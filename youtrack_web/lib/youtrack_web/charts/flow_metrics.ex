defmodule YoutrackWeb.Charts.FlowMetrics do
  @moduledoc """
  Flow Metrics chart specification builders.
  """

  alias YoutrackWeb.Charts.Primitives

  @sankey_palette [
    "#1d4ed8",
    "#0f766e",
    "#b45309",
    "#be123c",
    "#6d28d9",
    "#0369a1",
    "#3f6212",
    "#92400e"
  ]

  def build_chart_specs(inputs) do
    %{
      throughput: throughput_spec(inputs.throughput_by_week),
      throughput_by_person: throughput_by_person_spec(inputs.throughput_by_person),
      cycle_histogram: cycle_histogram_spec(inputs.cycle_time_data),
      cycle_by_stream: cycle_by_stream_spec(inputs.cycle_time_data),
      net_active_histogram:
        if(inputs.net_active_data == [],
          do: nil,
          else: net_active_histogram_spec(inputs.net_active_data)
        ),
      net_active_by_stream:
        if(inputs.net_active_data == [],
          do: nil,
          else: net_active_by_stream_spec(inputs.net_active_data)
        ),
      cycle_vs_net_active:
        if(inputs.net_active_data == [],
          do: nil,
          else: cycle_vs_net_active_spec(inputs.net_active_data)
        ),
      wip_by_person: wip_by_person_spec(inputs.wip_by_person),
      wip_by_stream: wip_by_stream_spec(inputs.wip_by_stream),
      context_switch_avg: context_switch_avg_spec(inputs.context_switch_avg),
      context_switch_heatmap: context_switch_heatmap_spec(inputs.context_switch_data),
      bus_factor: bus_factor_spec(inputs.bus_factor_data),
      long_running: long_running_spec(inputs.long_running),
      rotation_switches: rotation_switches_spec(inputs.rotation_metrics),
      rotation_tenure: rotation_tenure_spec(inputs.rotation_metrics),
      rotation_person_stream: rotation_person_stream_spec(inputs.rotation_person_stream),
      rotation_transition_sankey:
        rotation_transition_sankey_spec(inputs.rotation_transition_sankey),
      rotation_stream_tenure: rotation_stream_tenure_spec(inputs.stream_tenure),
      rework_by_stream:
        if(inputs.rework_by_stream == [],
          do: nil,
          else: rework_by_stream_spec(inputs.rework_by_stream)
        ),
      unplanned_by_stream: unplanned_by_stream_spec(inputs.unplanned_by_stream),
      unplanned_by_person: unplanned_by_person_spec(inputs.unplanned_by_person),
      unplanned_trend: unplanned_trend_spec(inputs.unplanned_trend)
    }
  end

  defp throughput_spec(values),
    do:
      layered_time_chart(values, "Throughput: Completed Items per Week", "completed", "Completed")

  defp throughput_by_person_spec(values),
    do: person_bar(values, "Throughput by Person", "completed", "Completed", "steelblue")

  defp cycle_histogram_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Cycle Time Distribution (days)",
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{
          "field" => "cycle_days",
          "type" => "quantitative",
          "bin" => %{"maxbins" => 20},
          "title" => "Cycle Time (days)"
        },
        "y" => %{"aggregate" => "count", "type" => "quantitative", "title" => "Count"}
      }
    }
  end

  defp cycle_by_stream_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Cycle Time by Workstream",
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "boxplot", "extent" => 1.5},
      "encoding" => %{
        "x" => %{
          "field" => "stream",
          "type" => "nominal",
          "title" => "Workstream",
          "sort" => "ascending"
        },
        "y" => %{
          "field" => "cycle_days",
          "type" => "quantitative",
          "title" => "Cycle Time (days)"
        },
        "color" => %{"field" => "stream", "type" => "nominal", "legend" => nil}
      }
    }
  end

  defp net_active_histogram_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Net Active Time Distribution (days)",
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{
          "field" => "net_active_days",
          "type" => "quantitative",
          "bin" => %{"maxbins" => 20},
          "title" => "Net Active Time (days)"
        },
        "y" => %{"aggregate" => "count", "type" => "quantitative", "title" => "Count"}
      }
    }
  end

  defp net_active_by_stream_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Net Active Time by Workstream",
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "boxplot", "extent" => 1.5},
      "encoding" => %{
        "x" => %{
          "field" => "stream",
          "type" => "nominal",
          "title" => "Workstream",
          "sort" => "ascending"
        },
        "y" => %{
          "field" => "net_active_days",
          "type" => "quantitative",
          "title" => "Net Active Time (days)"
        },
        "color" => %{"field" => "stream", "type" => "nominal", "legend" => nil}
      }
    }
  end

  defp cycle_vs_net_active_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Cycle Time vs Net Active Time by Workstream (median)",
      "width" => 600,
      "height" => 350,
      "data" => %{"values" => values},
      "transform" => [
        %{
          "fold" => ["cycle_days", "net_active_days"],
          "as" => ["metric", "days"]
        }
      ],
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{
          "field" => "stream",
          "type" => "nominal",
          "title" => "Workstream",
          "sort" => "ascending"
        },
        "y" => %{
          "field" => "days",
          "type" => "quantitative",
          "aggregate" => "median",
          "title" => "Median Days"
        },
        "color" => %{
          "field" => "metric",
          "type" => "nominal",
          "title" => "Metric",
          "scale" => %{
            "domain" => ["cycle_days", "net_active_days"],
            "range" => ["#4c78a8", "#72b7b2"]
          }
        },
        "xOffset" => %{"field" => "metric", "type" => "nominal"}
      }
    }
  end

  defp wip_by_person_spec(values),
    do: person_bar(values, "Current WIP per Person", "wip", "Active Items", nil)

  defp wip_by_stream_spec(values),
    do: stream_bar(values, "Current WIP by Workstream", "wip", "Active Items", "teal")

  defp context_switch_avg_spec(values),
    do:
      person_bar(
        values,
        "Avg Context Switching Index per Person",
        "avg_streams",
        "Avg Distinct Streams/Week",
        nil
      )

  defp context_switch_heatmap_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Context Switching: Streams per Person per Week",
      "width" => 700,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "rect", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
        "y" => %{
          "field" => "person",
          "type" => "nominal",
          "title" => "Person",
          "sort" => "ascending"
        },
        "color" => %{
          "field" => "distinct_streams",
          "type" => "quantitative",
          "title" => "Distinct Streams",
          "scale" => %{"scheme" => "oranges"}
        }
      }
    }
  end

  defp bus_factor_spec(values),
    do: stream_bar(values, "Bus Factor by Workstream", "bus_factor", "Unique Contributors", nil)

  defp long_running_spec(values), do: issue_age_bar(values, "Ongoing Items by Age (days)")

  defp rotation_switches_spec(values),
    do: person_bar(values, "Stream Switches per Person", "switches", "Stream Switches", nil)

  defp rotation_tenure_spec(values),
    do:
      person_bar(
        values,
        "Average Tenure per Stream (weeks)",
        "avg_tenure_weeks",
        "Avg Weeks on Same Stream",
        "mediumpurple"
      )

  defp rotation_person_stream_spec(values) do
    person_specs =
      values
      |> Enum.group_by(& &1.person)
      |> Enum.sort_by(fn {person, _rows} -> person end)
      |> Enum.map(fn {person, rows} ->
        %{
          "title" => %{
            "text" => person,
            "anchor" => "start",
            "fontSize" => 13,
            "fontWeight" => "bold",
            "offset" => 8
          },
          "width" => 700,
          "height" => %{"step" => 24},
          "data" => %{"values" => Enum.sort_by(rows, &{&1.stream, &1.week})},
          "mark" => %{
            "type" => "rect",
            "tooltip" => true,
            "cornerRadius" => 4,
            "stroke" => "white",
            "strokeWidth" => 1
          },
          "encoding" => %{
            "x" => %{
              "field" => "week",
              "type" => "nominal",
              "title" => "Week",
              "sort" => "ascending",
              "axis" => %{"labelAngle" => 0, "labelLimit" => 120}
            },
            "y" => %{
              "field" => "stream",
              "type" => "nominal",
              "title" => "Workstream",
              "sort" => "ascending",
              "axis" => %{"labelLimit" => 180}
            },
            "color" => %{
              "field" => "item_count",
              "type" => "quantitative",
              "title" => "Items",
              "scale" => %{"scheme" => "blues"}
            },
            "tooltip" => [
              %{"field" => "person", "type" => "nominal", "title" => "Person"},
              %{"field" => "stream", "type" => "nominal", "title" => "Workstream"},
              %{"field" => "week", "type" => "nominal", "title" => "Week"},
              %{"field" => "item_count", "type" => "quantitative", "title" => "Items"}
            ]
          },
          "config" => %{"view" => %{"stroke" => nil}}
        }
      end)

    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "autosize" => %{"type" => "pad", "contains" => "padding"},
      "title" => %{
        "text" => "Person × Week Activity",
        "subtitle" => "One panel per teammate; rows show streams touched each week"
      },
      "vconcat" => person_specs,
      "spacing" => 16,
      "config" => %{"view" => %{"stroke" => nil}}
    }
  end

  defp rotation_transition_sankey_spec(graph) do
    {nodes, links, height} = sankey_layout(graph)

    %{
      "$schema" => "https://vega.github.io/schema/vega/v5.json",
      "title" => %{
        "text" => "Week-to-Week Stream Transition Sankey",
        "subtitle" => "Transitions use all streams touched across consecutive weeks only"
      },
      "width" => 860,
      "height" => height,
      "padding" => %{"top" => 24, "left" => 24, "right" => 180, "bottom" => 20},
      "autosize" => %{"type" => "pad", "contains" => "padding"},
      "data" => [
        %{"name" => "links", "values" => links},
        %{"name" => "nodes", "values" => nodes}
      ],
      "marks" => [
        %{
          "type" => "path",
          "from" => %{"data" => "links"},
          "encode" => %{
            "enter" => %{
              "path" => %{"field" => "path"},
              "fill" => %{"field" => "fill"},
              "fillOpacity" => %{"value" => 0.35},
              "stroke" => %{"field" => "stroke"},
              "strokeOpacity" => %{"value" => 0.55},
              "strokeWidth" => %{"value" => 1},
              "tooltip" => %{"field" => "tooltip"}
            }
          }
        },
        %{
          "type" => "rect",
          "from" => %{"data" => "nodes"},
          "encode" => %{
            "enter" => %{
              "x" => %{"field" => "x0"},
              "x2" => %{"field" => "x1"},
              "y" => %{"field" => "y0"},
              "y2" => %{"field" => "y1"},
              "fill" => %{"field" => "fill"},
              "stroke" => %{"value" => "white"},
              "strokeWidth" => %{"value" => 1},
              "tooltip" => %{"field" => "tooltip"}
            }
          }
        },
        %{
          "type" => "text",
          "from" => %{"data" => "nodes"},
          "encode" => %{
            "enter" => %{
              "x" => %{"field" => "label_x"},
              "y" => %{"field" => "label_y"},
              "align" => %{"field" => "label_align"},
              "baseline" => %{"value" => "middle"},
              "fontSize" => %{"value" => 12},
              "fontWeight" => %{"value" => "bold"},
              "fill" => %{"value" => "#111827"},
              "text" => %{"field" => "label"}
            }
          }
        }
      ]
    }
  end

  defp rotation_stream_tenure_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Stream Tenure: Total Weeks per Person per Stream",
      "width" => 700,
      "height" => 400,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "person", "type" => "nominal", "title" => "Person"},
        "y" => %{
          "field" => "total_weeks",
          "type" => "quantitative",
          "title" => "Total Weeks",
          "stack" => "zero"
        },
        "color" => %{"field" => "stream", "type" => "nominal", "title" => "Workstream"}
      }
    }
  end

  defp rework_by_stream_spec(values),
    do: stream_bar(values, "Rework by Workstream", "rework_issues", "Reworked Issues", "coral")

  defp unplanned_by_stream_spec(values),
    do:
      stream_bar(
        values,
        "Unplanned Work by Workstream",
        "unplanned",
        "Unplanned Issues",
        "salmon"
      )

  defp unplanned_by_person_spec(values),
    do:
      person_bar(
        values,
        "Unplanned Work by Person",
        "unplanned",
        "Unplanned Issues",
        "darkorange"
      )

  defp unplanned_trend_spec(values),
    do:
      layered_time_chart(
        values,
        "Unplanned Work Trend (per week)",
        "unplanned",
        "Unplanned Issues"
      )

  defp layered_time_chart(values, title, field, y_title) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "width" => 700,
      "height" => 300,
      "data" => %{"values" => values},
      "layer" => [
        %{
          "mark" => %{"type" => "bar", "opacity" => 0.5, "color" => "salmon"},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
            "y" => %{"field" => field, "type" => "quantitative", "title" => y_title}
          }
        },
        %{
          "mark" => %{"type" => "line", "color" => "red", "point" => true},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal"},
            "y" => %{"field" => field, "type" => "quantitative"}
          }
        }
      ]
    }
  end

  defp person_bar(values, title, field, y_title, color) do
    Primitives.nominal_bar(values, title, "person", field, "Person", y_title, color: color)
  end

  defp stream_bar(values, title, field, y_title, color) do
    Primitives.nominal_bar(values, title, "stream", field, "Workstream", y_title, color: color)
  end

  defp issue_age_bar(values, title) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "width" => 700,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "issue_id", "type" => "nominal", "title" => "Issue", "sort" => "-y"},
        "y" => %{"field" => "age_days", "type" => "quantitative", "title" => "Age (days)"},
        "color" => %{
          "field" => "age_days",
          "type" => "quantitative",
          "scale" => %{"scheme" => "orangered"}
        }
      }
    }
  end

  defp sankey_layout(%{"nodes" => nodes, "links" => links}) do
    width = 860
    left_x0 = 80.0
    node_width = 18.0
    right_x0 = width - 240.0
    right_x1 = right_x0 + node_width
    left_x1 = left_x0 + node_width
    plot_top = 20.0
    node_gap = 18.0

    streams = nodes |> Enum.map(& &1["name"]) |> Enum.sort()
    color_map = sankey_color_map(streams)
    source_totals = stream_totals(links, "source")
    target_totals = stream_totals(links, "target")
    total_flow = Enum.max([Enum.sum(Map.values(source_totals)), 1])
    plot_height = max(320.0, total_flow * 34.0 + max(length(streams) - 1, 0) * node_gap)
    scale = (plot_height - max(length(streams) - 1, 0) * node_gap) / total_flow

    source_nodes =
      build_sankey_nodes(
        streams,
        source_totals,
        color_map,
        left_x0,
        left_x1,
        plot_top,
        node_gap,
        scale,
        :left
      )

    target_nodes =
      build_sankey_nodes(
        streams,
        target_totals,
        color_map,
        right_x0,
        right_x1,
        plot_top,
        node_gap,
        scale,
        :right
      )

    source_segments = link_segments(links, source_nodes, "source", "target", scale)
    target_segments = link_segments(links, target_nodes, "target", "source", scale)

    link_values =
      links
      |> Enum.sort_by(fn link -> {link["source"], link["target"]} end)
      |> Enum.map(fn link ->
        key = {link["source"], link["target"]}
        source_segment = Map.fetch!(source_segments, key)
        target_segment = Map.fetch!(target_segments, key)
        color = Map.fetch!(color_map, link["source"])

        %{
          "source" => link["source"],
          "target" => link["target"],
          "value" => link["value"],
          "people" => link["people"],
          "path" => sankey_path(left_x1, source_segment, right_x0, target_segment),
          "fill" => color,
          "stroke" => color,
          "tooltip" =>
            "#{link["source"]} -> #{link["target"]}\nPeople: #{link["people"]}\nTransitions: #{link["value"]}"
        }
      end)

    node_values =
      Enum.map(streams, fn stream ->
        left_node = Map.fetch!(source_nodes, stream)
        right_node = Map.fetch!(target_nodes, stream)
        color = Map.fetch!(color_map, stream)
        outgoing = Map.get(source_totals, stream, 0)
        incoming = Map.get(target_totals, stream, 0)

        [
          sankey_node_mark(stream, left_node, color, outgoing, incoming, :left),
          sankey_node_mark(stream, right_node, color, outgoing, incoming, :right)
        ]
      end)
      |> List.flatten()

    {node_values, link_values, trunc(plot_height + plot_top * 2)}
  end

  defp sankey_color_map(streams) do
    streams
    |> Enum.with_index()
    |> Map.new(fn {stream, index} ->
      {stream, Enum.at(@sankey_palette, rem(index, length(@sankey_palette)))}
    end)
  end

  defp stream_totals(links, field) do
    links
    |> Enum.group_by(& &1[field])
    |> Map.new(fn {stream, stream_links} ->
      {stream, Enum.sum(Enum.map(stream_links, & &1["value"]))}
    end)
  end

  defp build_sankey_nodes(streams, totals, color_map, x0, x1, plot_top, node_gap, scale, _side) do
    {nodes, _cursor} =
      Enum.reduce(streams, {%{}, plot_top}, fn stream, {acc, cursor} ->
        value = Map.get(totals, stream, 0)
        height = max(value * scale, 14.0)

        node = %{
          x0: x0,
          x1: x1,
          y0: cursor,
          y1: cursor + height,
          fill: Map.fetch!(color_map, stream),
          value: value
        }

        {Map.put(acc, stream, node), cursor + height + node_gap}
      end)

    nodes
  end

  defp link_segments(links, nodes, group_field, sort_field, scale) do
    links
    |> Enum.sort_by(fn link -> {link[group_field], link[sort_field]} end)
    |> Enum.reduce({%{}, %{}}, fn link, {segments, offsets} ->
      stream = link[group_field]
      node = Map.fetch!(nodes, stream)
      offset = Map.get(offsets, stream, node.y0)
      segment_height = link["value"] * scale

      segment = %{
        y0: offset,
        y1: offset + segment_height
      }

      key = {link["source"], link["target"]}

      {
        Map.put(segments, key, segment),
        Map.put(offsets, stream, offset + segment_height)
      }
    end)
    |> elem(0)
  end

  defp sankey_path(source_x, source_segment, target_x, target_segment) do
    curve_x = source_x + (target_x - source_x) / 2

    source_y0 = source_segment.y0
    source_y1 = source_segment.y1
    target_y0 = target_segment.y0
    target_y1 = target_segment.y1

    [
      "M",
      float(source_x),
      ",",
      float(source_y0),
      " C",
      float(curve_x),
      ",",
      float(source_y0),
      " ",
      float(curve_x),
      ",",
      float(target_y0),
      " ",
      float(target_x),
      ",",
      float(target_y0),
      " L",
      float(target_x),
      ",",
      float(target_y1),
      " C",
      float(curve_x),
      ",",
      float(target_y1),
      " ",
      float(curve_x),
      ",",
      float(source_y1),
      " ",
      float(source_x),
      ",",
      float(source_y1),
      " Z"
    ]
    |> IO.iodata_to_binary()
  end

  defp sankey_node_mark(stream, node, color, outgoing, incoming, side) do
    label_x = if side == :left, do: node.x0 - 10.0, else: node.x1 + 10.0
    label_align = if side == :left, do: "right", else: "left"

    %{
      "name" => stream,
      "x0" => node.x0,
      "x1" => node.x1,
      "y0" => node.y0,
      "y1" => node.y1,
      "fill" => color,
      "label" => stream,
      "label_x" => label_x,
      "label_y" => (node.y0 + node.y1) / 2,
      "label_align" => label_align,
      "tooltip" =>
        "#{stream}\nOutgoing transitions: #{outgoing}\nIncoming transitions: #{incoming}"
    }
  end

  defp float(value) do
    value
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
  end
end
