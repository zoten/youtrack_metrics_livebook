defmodule YoutrackWeb.Charts.Gantt do
  @moduledoc """
  Gantt chart specification builders.
  """

  alias Youtrack.Workstreams

  def build_chart_specs(work_items) do
    unplanned_items = Enum.filter(work_items, & &1.is_unplanned)
    planned_items = Enum.reject(work_items, & &1.is_unplanned)

    pie_data = [
      %{type: "Planned", count: length(planned_items)},
      %{type: "Unplanned", count: length(unplanned_items)}
    ]

    person_stats =
      work_items
      |> Enum.group_by(& &1.person_name)
      |> Enum.map(fn {person, items} ->
        total = length(items)
        unplanned = Enum.count(items, & &1.is_unplanned)
        pct = if total > 0, do: Float.round(unplanned / total * 100, 1), else: 0.0
        %{person: person, total: total, unplanned: unplanned, unplanned_pct: pct}
      end)
      |> Enum.sort_by(& &1.unplanned_pct, :desc)

    stream_stats =
      work_items
      |> Enum.group_by(& &1.stream)
      |> Enum.map(fn {stream, items} ->
        total = length(items)
        unplanned = Enum.count(items, & &1.is_unplanned)
        pct = if total > 0, do: Float.round(unplanned / total * 100, 1), else: 0.0
        %{stream: stream, total: total, unplanned: unplanned, unplanned_pct: pct}
      end)
      |> Enum.sort_by(& &1.unplanned_pct, :desc)

    unplanned_dates =
      unplanned_items
      |> Enum.filter(&is_integer(&1.created))
      |> Enum.map(fn item ->
        date = item.created |> div(1000) |> DateTime.from_unix!() |> DateTime.to_date()
        weekday = Date.day_of_week(date)

        %{
          date: Date.to_iso8601(date),
          weekday_name: weekday_name(weekday),
          monthday: date.day
        }
      end)

    weekday_counts =
      unplanned_dates
      |> Enum.frequencies_by(& &1.weekday_name)
      |> Enum.map(fn {weekday, count} -> %{weekday: weekday, count: count} end)

    monthday_counts =
      unplanned_dates
      |> Enum.frequencies_by(& &1.monthday)
      |> Enum.map(fn {monthday, count} -> %{monthday: monthday, count: count} end)
      |> Enum.sort_by(& &1.monthday)

    unclassified_slug_counts =
      work_items
      |> Enum.filter(&(&1.stream == "(unclassified)"))
      |> Enum.frequencies_by(fn wi ->
        wi.title |> Workstreams.summary_slug() |> Workstreams.canonical_slug()
      end)
      |> Enum.map(fn {slug, count} -> %{slug: slug, count: count} end)
      |> Enum.sort_by(& &1.count, :desc)

    %{
      gantt: gantt_spec(work_items),
      planned_unplanned: planned_unplanned_spec(pie_data),
      unplanned_person: unplanned_by_person_spec(person_stats),
      unplanned_stream: unplanned_by_stream_spec(stream_stats),
      interrupts_weekday: interrupts_weekday_spec(weekday_counts),
      interrupts_monthday: interrupts_monthday_spec(monthday_counts),
      unclassified_slug: unclassified_slug_spec(unclassified_slug_counts)
    }
  end

  defp gantt_spec(work_items) do
    values =
      Enum.map(work_items, fn wi ->
        %{
          issue_id: wi.issue_id,
          title: wi.title,
          person_name: wi.person_name,
          stream: wi.stream,
          status: wi.status,
          work_type: if(wi.is_unplanned, do: "unplanned", else: "planned"),
          start: iso8601_ms(wi.start_at),
          end: iso8601_ms(wi.end_at)
        }
      end)

    stream_count =
      values |> Enum.map(& &1.stream) |> Enum.uniq() |> length() |> max(3)

    row_height = stream_count * 18 + 40

    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "data" => %{"values" => values},
      "facet" => %{
        "row" => %{
          "field" => "person_name",
          "type" => "nominal",
          "header" => %{"title" => nil, "labelFontSize" => 13, "labelPadding" => 8}
        }
      },
      "spec" => %{
        "width" => "container",
        "height" => row_height,
        "mark" => %{"type" => "bar", "tooltip" => true},
        "encoding" => %{
          "x" => %{"field" => "start", "type" => "temporal", "title" => "Time"},
          "x2" => %{"field" => "end"},
          "y" => %{"field" => "stream", "type" => "nominal", "title" => "Stream"},
          "color" => %{
            "field" => "work_type",
            "type" => "nominal",
            "title" => "Work Type",
            "scale" => %{
              "domain" => ["planned", "unplanned"],
              "range" => ["steelblue", "orangered"]
            }
          },
          "opacity" => %{
            "field" => "status",
            "type" => "nominal",
            "title" => "Status",
            "scale" => %{
              "domain" => ["finished", "ongoing", "unfinished"],
              "range" => [0.4, 1.0, 0.7]
            }
          }
        }
      }
    }
  end

  defp planned_unplanned_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Planned vs Unplanned Work",
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

  defp unplanned_by_person_spec(values),
    do: person_bar(values, "Unplanned Work % by Person", "unplanned_pct", "Unplanned %")

  defp unplanned_by_stream_spec(values),
    do: stream_bar(values, "Unplanned Work % by Workstream", "unplanned_pct", "Unplanned %")

  defp interrupts_weekday_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Interrupts by Day of Week",
      "width" => 420,
      "height" => 200,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true, "color" => "orangered"},
      "encoding" => %{
        "x" => %{
          "field" => "weekday",
          "type" => "ordinal",
          "sort" => ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
          "title" => "Day"
        },
        "y" => %{"field" => "count", "type" => "quantitative", "title" => "Interrupt Count"}
      }
    }
  end

  defp interrupts_monthday_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Interrupts by Day of Month",
      "width" => 620,
      "height" => 200,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true, "color" => "orangered"},
      "encoding" => %{
        "x" => %{"field" => "monthday", "type" => "ordinal", "title" => "Day of Month"},
        "y" => %{"field" => "count", "type" => "quantitative", "title" => "Interrupt Count"}
      }
    }
  end

  defp unclassified_slug_spec(values) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => "Unclassified Slugs",
      "width" => 600,
      "height" => 280,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true, "color" => "#f97352"},
      "encoding" => %{
        "x" => %{"field" => "slug", "type" => "nominal", "title" => "Slug", "sort" => "-y"},
        "y" => %{"field" => "count", "type" => "quantitative", "title" => "Issues"}
      }
    }
  end

  defp person_bar(values, title, y_field, y_title) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "person", "type" => "nominal", "title" => "Person", "sort" => "-y"},
        "y" => %{"field" => y_field, "type" => "quantitative", "title" => y_title},
        "color" => %{
          "field" => y_field,
          "type" => "quantitative",
          "scale" => %{"scheme" => "oranges"}
        }
      }
    }
  end

  defp stream_bar(values, title, y_field, y_title) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v5.json",
      "title" => title,
      "width" => 600,
      "height" => 300,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "tooltip" => true},
      "encoding" => %{
        "x" => %{"field" => "stream", "type" => "nominal", "title" => "Stream", "sort" => "-y"},
        "y" => %{"field" => y_field, "type" => "quantitative", "title" => y_title},
        "color" => %{
          "field" => y_field,
          "type" => "quantitative",
          "scale" => %{"scheme" => "oranges"}
        }
      }
    }
  end

  defp weekday_name(1), do: "Mon"
  defp weekday_name(2), do: "Tue"
  defp weekday_name(3), do: "Wed"
  defp weekday_name(4), do: "Thu"
  defp weekday_name(5), do: "Fri"
  defp weekday_name(6), do: "Sat"
  defp weekday_name(7), do: "Sun"
  defp weekday_name(_), do: "?"

  defp iso8601_ms(nil), do: nil

  defp iso8601_ms(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end
end