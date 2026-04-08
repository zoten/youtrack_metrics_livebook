defmodule YoutrackWeb.Charts.FlowMetrics do
  @moduledoc """
  Flow Metrics chart specification builders.
  """

  alias YoutrackWeb.Charts.Primitives

  def build_chart_specs(inputs) do
    %{
      throughput: throughput_spec(inputs.throughput_by_week),
      throughput_by_person: throughput_by_person_spec(inputs.throughput_by_person),
      cycle_histogram: cycle_histogram_spec(inputs.cycle_time_data),
      cycle_by_stream: cycle_by_stream_spec(inputs.cycle_time_data),
      net_active_histogram:
        if(inputs.net_active_data == [], do: nil, else: net_active_histogram_spec(inputs.net_active_data)),
      net_active_by_stream:
        if(inputs.net_active_data == [], do: nil, else: net_active_by_stream_spec(inputs.net_active_data)),
      cycle_vs_net_active:
        if(inputs.net_active_data == [], do: nil, else: cycle_vs_net_active_spec(inputs.net_active_data)),
      wip_by_person: wip_by_person_spec(inputs.wip_by_person),
      wip_by_stream: wip_by_stream_spec(inputs.wip_by_stream),
      context_switch_avg: context_switch_avg_spec(inputs.context_switch_avg),
      context_switch_heatmap: context_switch_heatmap_spec(inputs.context_switch_data),
      bus_factor: bus_factor_spec(inputs.bus_factor_data),
      long_running: long_running_spec(inputs.long_running),
      rotation_switches: rotation_switches_spec(inputs.rotation_metrics),
      rotation_tenure: rotation_tenure_spec(inputs.rotation_metrics),
      rotation_person_stream: rotation_person_stream_spec(inputs.rotation_person_stream),
      rotation_stream_tenure: rotation_stream_tenure_spec(inputs.stream_tenure),
      rework_by_stream:
        if(inputs.rework_by_stream == [], do: nil, else: rework_by_stream_spec(inputs.rework_by_stream)),
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
          },
          "legend" => %{
            "labelExpr" => "datum.label === 'cycle_days' ? 'Cycle Time' : 'Net Active Time'"
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
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Person × Week: Workstream Activity",
      "width" => 700,
      "height" => 400,
      "data" => %{"values" => values},
      "mark" => %{"type" => "rect", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
        "y" => %{"field" => "person", "type" => "nominal", "title" => "Person"},
        "color" => %{"field" => "stream", "type" => "nominal", "title" => "Workstream"}
      }
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
    do: stream_bar(values, "Unplanned Work by Workstream", "unplanned", "Unplanned Issues", "salmon")

  defp unplanned_by_person_spec(values),
    do: person_bar(values, "Unplanned Work by Person", "unplanned", "Unplanned Issues", "darkorange")

  defp unplanned_trend_spec(values),
    do: layered_time_chart(values, "Unplanned Work Trend (per week)", "unplanned", "Unplanned Issues")

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
end