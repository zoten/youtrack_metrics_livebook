defmodule YoutrackWeb.ChartSpecs do
  @moduledoc """
  Helper module for generating VegaLite chart specifications.

  Provides sample specs for testing and references for building real analytics specs.
  """

  @doc """
  Generate a sample bar chart for testing the VegaLite hook.

  Returns a VegaLite specification as a map suitable for JSON encoding.
  """
  def sample_bar_chart do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "description" => "A simple bar chart with embedded data.",
      "data" => %{
        "values" => [
          %{"a" => "A", "b" => 28},
          %{"a" => "B", "b" => 55},
          %{"a" => "C", "b" => 43},
          %{"a" => "D", "b" => 91},
          %{"a" => "E", "b" => 81},
          %{"a" => "F", "b" => 53},
          %{"a" => "G", "b" => 19},
          %{"a" => "H", "b" => 87}
        ]
      },
      "mark" => "bar",
      "encoding" => %{
        "x" => %{"field" => "a", "type" => "nominal", "axis" => %{"labelAngle" => 0}},
        "y" => %{"field" => "b", "type" => "quantitative"},
        "color" => %{
          "field" => "b",
          "type" => "quantitative",
          "scale" => %{"scheme" => "oranges"}
        }
      },
      "config" => %{
        "axis" => %{"labelFontSize" => 12, "titleFontSize" => 14},
        "legend" => %{"labelFontSize" => 12, "titleFontSize" => 14}
      }
    }
  end

  @doc """
  Generate a sample line chart for testing trends.
  """
  def sample_line_chart do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "description" => "A simple line chart for testing VegaLite integration.",
      "data" => %{
        "values" => [
          %{"month" => "Jan", "issues" => 42},
          %{"month" => "Feb", "issues" => 45},
          %{"month" => "Mar", "issues" => 38},
          %{"month" => "Apr", "issues" => 51},
          %{"month" => "May", "issues" => 48},
          %{"month" => "Jun", "issues" => 62}
        ]
      },
      "mark" => "line",
      "encoding" => %{
        "x" => %{
          "field" => "month",
          "type" => "nominal",
          "sort" => ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
        },
        "y" => %{"field" => "issues", "type" => "quantitative"},
        "color" => %{"value" => "#f97352"},
        "point" => %{"color" => "#f97352"},
        "tooltip" => [
          %{"field" => "month", "type" => "nominal"},
          %{"field" => "issues", "type" => "quantitative"}
        ]
      },
      "config" => %{
        "axis" => %{"labelFontSize" => 12, "titleFontSize" => 14},
        "mark" => %{"point" => true}
      }
    }
  end

  @doc """
  Generate an empty placeholder spec for sections not yet implemented.
  """
  def placeholder_spec(section_name) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "description" => "Placeholder for #{section_name}",
      "data" => %{
        "values" => [%{"x" => 1, "y" => 1}]
      },
      "mark" => "point",
      "encoding" => %{
        "x" => %{"field" => "x", "type" => "quantitative", "axis" => nil},
        "y" => %{"field" => "y", "type" => "quantitative", "axis" => nil}
      },
      "config" => %{
        "view" => %{"continuousWidth" => 0, "continuousHeight" => 0}
      }
    }
  end
end
