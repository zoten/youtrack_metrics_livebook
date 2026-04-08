defmodule YoutrackWeb.Charts.Pairing do
  @moduledoc """
  Pairing chart specification builders.
  """

  alias Youtrack.PairingAnalysis
  alias YoutrackWeb.Charts.Primitives

  def build_chart_specs(pair_records) do
    matrix_data = PairingAnalysis.pair_matrix(pair_records)
    trend_data = PairingAnalysis.trend_by_week(pair_records)
    workstream_data = PairingAnalysis.by_workstream(pair_records)

    top_pairs_data =
      pair_records
      |> Enum.frequencies_by(&{&1.person_a, &1.person_b})
      |> Enum.sort_by(fn {_pair, count} -> count end, :desc)
      |> Enum.take(15)
      |> Enum.map(fn {{person_a, person_b}, count} -> %{pair: "#{person_a} + #{person_b}", count: count} end)

    firefighter_persons = PairingAnalysis.firefighters_by_person(pair_records)
    firefighter_pairs = PairingAnalysis.firefighters_by_pair(pair_records) |> Enum.take(15)

    interrupt_trend = PairingAnalysis.interrupt_trend_by_week(pair_records)
    interrupt_by_person = PairingAnalysis.interrupt_trend_by_person(pair_records)

    planned_unplanned = [
      %{type: "Planned", count: Enum.count(pair_records, &(!&1.is_unplanned))},
      %{type: "Unplanned", count: Enum.count(pair_records, & &1.is_unplanned)}
    ]

    involvement_by_person =
      firefighter_persons
      |> Enum.map(fn row -> %{person: row.person, total: row.total} end)
      |> Enum.sort_by(& &1.total, :desc)

    by_project =
      pair_records
      |> Enum.frequencies_by(&(&1.project || "(none)"))
      |> Enum.map(fn {project, pair_count} -> %{project: project, pair_count: pair_count} end)
      |> Enum.sort_by(& &1.pair_count, :desc)

    %{
      pair_matrix: pair_matrix_spec(matrix_data),
      pairing_trend: pairing_trend_spec(trend_data),
      pairing_by_workstream: pairing_workstream_spec(workstream_data),
      top_pairs: top_pairs_spec(top_pairs_data),
      firefighter_person: firefighter_person_spec(firefighter_persons),
      firefighter_pair: firefighter_pair_spec(firefighter_pairs),
      interrupt_aggregate: interrupt_aggregate_spec(interrupt_trend),
      interrupt_person: interrupt_person_spec(interrupt_by_person),
      planned_unplanned: planned_unplanned_spec(planned_unplanned),
      involvement_by_person: involvement_by_person_spec(involvement_by_person),
      pairing_by_project: pairing_by_project_spec(by_project)
    }
  end

  defp pair_matrix_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Pair Matrix",
      "width" => 500,
      "height" => 500,
      "data" => %{"values" => values},
      "mark" => %{"type" => "rect", "tooltip" => true},
      "encoding" => %{
        "x" => %{
          "field" => "person_a",
          "type" => "nominal",
          "title" => "Person",
          "sort" => "ascending"
        },
        "y" => %{
          "field" => "person_b",
          "type" => "nominal",
          "title" => "Person",
          "sort" => "ascending"
        },
        "color" => %{
          "field" => "count",
          "type" => "quantitative",
          "title" => "Times paired",
          "scale" => %{"scheme" => "blues"}
        }
      }
    }
  end

  defp pairing_trend_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Pairing Trend by Week",
      "width" => 700,
      "height" => 300,
      "data" => %{"values" => values},
      "layer" => [
        %{
          "mark" => %{"type" => "bar", "opacity" => 0.6},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
            "y" => %{
              "field" => "pair_count",
              "type" => "quantitative",
              "title" => "Pair occurrences"
            }
          }
        },
        %{
          "mark" => %{"type" => "line", "color" => "red", "point" => true},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal"},
            "y" => %{
              "field" => "unique_pairs",
              "type" => "quantitative",
              "title" => "Unique pairs"
            }
          }
        }
      ]
    }
  end

  defp pairing_workstream_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Pairing by Workstream",
      "width" => 500,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{
          "field" => "workstream",
          "type" => "nominal",
          "title" => "Workstream",
          "sort" => "-y"
        },
        "y" => %{"field" => "pair_count", "type" => "quantitative", "title" => "Pair occurrences"},
        "color" => %{
          "field" => "unique_pairs",
          "type" => "quantitative",
          "title" => "Unique pairs",
          "scale" => %{"scheme" => "oranges"}
        }
      }
    }
  end

  defp top_pairs_spec(values),
    do:
      Primitives.nominal_bar(
        values,
        "Top 15 Pairs",
        "pair",
        "count",
        "Pair",
        "Occurrences",
        color: "#3b82f6"
      )

  defp firefighter_person_spec(values),
    do:
      Primitives.nominal_bar(
        values,
        "Firefighters: Unplanned Work by Person",
        "person",
        "unplanned",
        "Person",
        "Unplanned Pair Occurrences"
      )

  defp firefighter_pair_spec(values),
    do:
      Primitives.nominal_bar(
        values,
        "Firefighter Pairs: Top 15",
        "pair",
        "unplanned",
        "Pair",
        "Unplanned Occurrences",
        color: "orangered"
      )

  defp interrupt_aggregate_spec(values),
    do:
      Primitives.time_bar(
        values,
        "Interrupt Frequency Over Time (Aggregate)",
        "interrupt_count",
        "Interrupt Count"
      )

  defp interrupt_person_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Interrupt Frequency by Person Over Time",
      "width" => 700,
      "height" => 400,
      "data" => %{"values" => values},
      "mark" => %{"type" => "line", "point" => true, "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
        "y" => %{
          "field" => "interrupt_count",
          "type" => "quantitative",
          "title" => "Interrupt Count"
        },
        "color" => %{"field" => "person", "type" => "nominal", "title" => "Person"}
      }
    }
  end

  defp planned_unplanned_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Planned vs Unplanned Pair Occurrences",
      "width" => 320,
      "height" => 320,
      "data" => %{"values" => values},
      "mark" => %{"type" => "arc", "tooltip" => true},
      "encoding" => %{
        "theta" => %{"field" => "count", "type" => "quantitative"},
        "color" => %{
          "field" => "type",
          "type" => "nominal",
          "scale" => %{
            "domain" => ["Planned", "Unplanned"],
            "range" => ["steelblue", "orangered"]
          }
        }
      }
    }
  end

  defp involvement_by_person_spec(values),
    do:
      Primitives.nominal_bar(
        values,
        "Pair Involvement by Person",
        "person",
        "total",
        "Person",
        "Pair Involvement",
        color: "#10b981"
      )

  defp pairing_by_project_spec(values),
    do:
      Primitives.nominal_bar(
        values,
        "Pairing by Project",
        "project",
        "pair_count",
        "Project",
        "Pair Occurrences",
        color: "#8b5cf6"
      )

end