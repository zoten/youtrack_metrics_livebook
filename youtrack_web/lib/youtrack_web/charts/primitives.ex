defmodule YoutrackWeb.Charts.Primitives do
  @moduledoc """
  Reusable VegaLite chart primitives shared across chart modules.
  """

  def nominal_bar(values, title, x_field, y_field, x_title, y_title, opts \\ []) do
    color = Keyword.get(opts, :color)
    sort = Keyword.get(opts, :sort, "-y")
    height = Keyword.get(opts, :height, 300)

    mark =
      if color,
        do: %{"type" => "bar", "tooltip" => true, "color" => color},
        else: %{"type" => "bar", "tooltip" => true}

    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "height" => height,
      "data" => %{"values" => values},
      "mark" => mark,
      "encoding" => %{
        "x" => %{"field" => x_field, "type" => "nominal", "title" => x_title, "sort" => sort},
        "y" => %{"field" => y_field, "type" => "quantitative", "title" => y_title}
      }
    }
  end

  def time_bar(values, title, y_field, y_title, opts \\ []) do
    color = Keyword.get(opts, :color, "orangered")
    height = Keyword.get(opts, :height, 300)
    x_field = Keyword.get(opts, :x_field, "week")
    x_title = Keyword.get(opts, :x_title, "Week")

    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "height" => height,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true, "color" => color},
      "encoding" => %{
        "x" => %{"field" => x_field, "type" => "temporal", "title" => x_title},
        "y" => %{"field" => y_field, "type" => "quantitative", "title" => y_title}
      }
    }
  end
end
