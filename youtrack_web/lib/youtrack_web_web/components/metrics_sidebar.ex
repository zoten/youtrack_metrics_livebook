defmodule YoutrackWeb.Components.MetricsSidebar do
  @moduledoc false

  use Phoenix.Component

  import YoutrackWeb.CoreComponents, only: [input: 1]

  alias YoutrackWeb.Configuration

  attr(:config, :map, required: true)
  attr(:config_form, :any, required: true)
  attr(:config_open?, :boolean, default: true)
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
              <dd class="metrics-code mt-1 text-xs text-[color:var(--metrics-accent)]">
                {@config["workstreams_path"]}
              </dd>
            </div>
            <div>
              <dt class="metrics-copy">Prompts</dt>
              <dd class="metrics-code mt-1 text-xs text-[color:var(--metrics-accent)]">
                {@config["prompts_path"]}
              </dd>
            </div>
          </dl>
        </div>

        <div class="metrics-card rounded-3xl p-4 space-y-4">
          <div class="flex items-center justify-between gap-2">
            <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Configuration</p>
            <button
              id="toggle-sidebar-shared-config"
              type="button"
              phx-click="toggle_config"
              class="metrics-button metrics-button-ghost rounded-full px-3 py-1 text-[11px] font-semibold uppercase tracking-[0.16em]"
            >
              {if(@config_open?, do: "⬆️", else: "⬇️")}
            </button>
          </div>

          <%= if @config_open? do %>
            <.form
              for={@config_form}
              id="sidebar-shared-config-form"
              phx-change="config_changed"
              phx-hook="SharedConfigBridge"
              class="grid grid-cols-1 gap-3"
            >
              <.input field={@config_form[:base_url]} type="text" label="Base URL" />
              <.input field={@config_form[:token]} type="password" label="Token" />
              <.input field={@config_form[:base_query]} type="text" label="Base query" />
              <.input field={@config_form[:days_back]} type="number" label="Days back" />
              <.input field={@config_form[:state_field]} type="text" label="State field" />
              <.input field={@config_form[:assignees_field]} type="text" label="Assignees field" />
              <.input field={@config_form[:project_prefix]} type="text" label="Project prefix" />
              <.input
                field={@config_form[:excluded_logins]}
                type="text"
                label="Excluded logins (CSV)"
              />
              <.input
                field={@config_form[:in_progress_names]}
                type="text"
                label="In-progress states (CSV)"
              />
              <.input field={@config_form[:done_state_names]} type="text" label="Done states (CSV)" />
              <.input field={@config_form[:unplanned_tag]} type="text" label="Unplanned tag" />
              <.input
                field={@config_form[:use_activities]}
                type="select"
                label="Use activities"
                options={[{"Yes", "true"}, {"No", "false"}]}
              />
              <.input
                field={@config_form[:include_substreams]}
                type="select"
                label="Include substreams"
                options={[{"Yes", "true"}, {"No", "false"}]}
              />
              <.input field={@config_form[:workstreams_path]} type="text" label="Workstreams path" />
              <.input
                field={@config_form[:effort_mappings_path]}
                type="text"
                label="Effort mappings path"
              />
              <.input field={@config_form[:prompts_path]} type="text" label="Prompts path" />
            </.form>
          <% end %>
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
  defp section_path("card_focus"), do: "/card"
  defp section_path("workstream_config"), do: "/workstreams"
  defp section_path("comparison"), do: "/compare"
  defp section_path("workstream_analyzer"), do: "/workstream-analyzer"
  defp section_path(_), do: "/"
end
