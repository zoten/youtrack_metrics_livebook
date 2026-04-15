defmodule YoutrackWeb.Charts.WorkstreamAnalyzer do
  @moduledoc """
  Chart specification builders for Workstream Analyzer.
  """

  def build_chart_specs(%{
        compare_series: compare_series,
        composition_series: composition_series,
        composition_totals: composition_totals
      }) do
    %{
      compare_effort:
        if(compare_series == [], do: nil, else: compare_effort_spec(compare_series)),
      composition_effort:
        if(composition_series == [],
          do: nil,
          else: composition_effort_spec(composition_series, composition_totals)
        )
    }
  end

  defp compare_effort_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Effort over time by workstream",
      "height" => 360,
      "data" => %{"values" => values},
      "layer" => [
        %{
          "mark" => %{"type" => "area", "opacity" => 0.18, "interpolate" => "monotone"},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
            "y" => %{"field" => "effort", "type" => "quantitative", "title" => "Effort units"},
            "color" => %{"field" => "stream", "type" => "nominal", "title" => "Workstream"}
          }
        },
        %{
          "mark" => %{"type" => "line", "point" => true, "interpolate" => "monotone"},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
            "y" => %{"field" => "effort", "type" => "quantitative", "title" => "Effort units"},
            "color" => %{"field" => "stream", "type" => "nominal", "title" => "Workstream"},
            "tooltip" => [
              %{"field" => "stream", "type" => "nominal", "title" => "Workstream"},
              %{"field" => "week", "type" => "temporal", "title" => "Week"},
              %{
                "field" => "effort",
                "type" => "quantitative",
                "title" => "Effort",
                "format" => ".2f"
              }
            ]
          }
        }
      ]
    }
  end

  defp composition_effort_spec(series, totals) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Substream composition over time",
      "height" => 360,
      "layer" => [
        %{
          "data" => %{"values" => series},
          "mark" => %{"type" => "area", "interpolate" => "monotone"},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal", "title" => "Week"},
            "y" => %{
              "field" => "effort",
              "type" => "quantitative",
              "stack" => "zero",
              "title" => "Effort units"
            },
            "color" => %{"field" => "substream", "type" => "nominal", "title" => "Substream"},
            "tooltip" => [
              %{"field" => "substream", "type" => "nominal", "title" => "Substream"},
              %{"field" => "week", "type" => "temporal", "title" => "Week"},
              %{
                "field" => "effort",
                "type" => "quantitative",
                "title" => "Effort",
                "format" => ".2f"
              }
            ]
          }
        },
        %{
          "data" => %{"values" => totals},
          "mark" => %{"type" => "line", "color" => "#111827", "point" => true},
          "encoding" => %{
            "x" => %{"field" => "week", "type" => "temporal"},
            "y" => %{"field" => "total_effort", "type" => "quantitative"},
            "tooltip" => [
              %{"field" => "week", "type" => "temporal", "title" => "Week"},
              %{
                "field" => "total_effort",
                "type" => "quantitative",
                "title" => "Total effort",
                "format" => ".2f"
              }
            ]
          }
        }
      ]
    }
  end
end
