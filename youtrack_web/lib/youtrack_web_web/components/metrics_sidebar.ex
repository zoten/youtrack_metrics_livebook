defmodule YoutrackWeb.Components.MetricsSidebar do
  @moduledoc false

  use Phoenix.Component

  alias YoutrackWeb.Configuration

  attr(:config, :map, required: true)
  attr(:active_section, :string, default: nil)
  attr(:freshness, :any, default: nil)

  def metrics_sidebar(assigns) do
    assigns =
      assigns
      |> assign(:sections, Configuration.sections())
      |> assign(:freshness_info, freshness_info(assigns.freshness))

    ~H"""
    <aside class="metrics-sidebar px-5 py-6 sm:px-6">
      <div class="space-y-6">
        <div class="space-y-3">
          <p class="metrics-eyebrow text-xs uppercase tracking-[0.28em]">Local cockpit</p>
          <div class="space-y-2">
            <h1 class="metrics-brand metrics-title text-4xl leading-none">YouTrack Metrics</h1>
            <p class="metrics-copy max-w-xs text-sm leading-6">
              Keep context while moving between views. Every section uses the same source data
              and shared defaults.
            </p>
          </div>
        </div>

        <nav aria-label="Dashboard sections" class="space-y-2">
          <%= for section <- @sections do %>
            <.link
              id={"nav-#{section.id}"}
              navigate={section_path(section.id)}
              aria-current={if(@active_section == section.id, do: "page", else: nil)}
              class={[
                "metrics-link metrics-nav-link block rounded-3xl border px-4 py-3",
                @active_section == section.id && "metrics-nav-link-active",
                @active_section != section.id &&
                  "metrics-nav-link-idle"
              ]}
            >
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="metrics-title text-sm font-semibold">{section.label}</p>
                  <p class="metrics-copy mt-1 text-xs uppercase tracking-[0.2em]">
                    {section.visuals}
                  </p>
                </div>
                <span class="metrics-pill metrics-pill-success px-2 py-1 text-[11px]">
                  {section.stage}
                </span>
              </div>
            </.link>
          <% end %>
        </nav>

        <div class="metrics-card rounded-3xl p-4">
          <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Data freshness</p>
          <p
            id="sidebar-freshness"
            class="metrics-title mt-2 text-xs leading-5"
            title={@freshness_info.full}
          >
            {@freshness_info.short}
          </p>
        </div>

        <div class="metrics-card rounded-3xl p-4">
          <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Shared paths</p>
          <dl class="metrics-title mt-3 space-y-3 text-sm">
            <div>
              <dt class="metrics-copy">Workstreams</dt>
              <dd class="metrics-code mt-1 text-xs text-[color:var(--metrics-accent)]">{@config["workstreams_path"]}</dd>
            </div>
            <div>
              <dt class="metrics-copy">Prompts</dt>
              <dd class="metrics-code mt-1 text-xs text-[color:var(--metrics-accent)]">{@config["prompts_path"]}</dd>
            </div>
          </dl>
        </div>
      </div>
    </aside>
    """
  end

  defp freshness_info(nil) do
    %{short: "No data fetched yet", full: "No fetch has been executed yet"}
  end

  defp freshness_info(cache_state) when is_atom(cache_state) do
    source = source_label(cache_state)
    %{short: "Last fetch source: #{source}", full: "Last fetch source: #{source}"}
  end

  defp freshness_info(%{} = cache_state) do
    source = source_label(Map.get(cache_state, :source))

    case Map.get(cache_state, :fetched_at_ms) do
      ms when is_integer(ms) ->
        dt = DateTime.from_unix!(ms, :millisecond)
        stamp = Calendar.strftime(dt, "%Y/%m/%d %H:%M")
        relative = relative_ago(ms)
        full = "#{source}, fetched #{relative}, #{stamp}"

        %{
          short: "#{source}, fetched #{relative}",
          full: full
        }

      _ ->
        %{short: "Last fetch source: #{source}", full: "Last fetch source: #{source}"}
    end
  end

  defp source_label(:hit), do: "cache hit"
  defp source_label(:miss), do: "cache miss"
  defp source_label(:refresh), do: "refresh"
  defp source_label(_), do: "unknown"

  defp relative_ago(ms) do
    now = System.system_time(:millisecond)
    seconds = max(div(now - ms, 1000), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)} minute(s) ago"
      true -> "#{div(seconds, 3600)} hour(s) ago"
    end
  end

  defp section_path("flow_metrics"), do: "/flow-metrics"
  defp section_path("gantt"), do: "/gantt"
  defp section_path("pairing"), do: "/pairing"
  defp section_path("weekly_report"), do: "/weekly-report"
  defp section_path(_), do: "/"
end
