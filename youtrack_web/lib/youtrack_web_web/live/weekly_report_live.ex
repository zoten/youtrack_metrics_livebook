defmodule YoutrackWeb.WeeklyReportLive do
  @moduledoc """
  Weekly Report section with payload generation and optional LLM summarization.
  """

  use YoutrackWeb, :live_view

  alias Youtrack.Client
  alias Youtrack.WeeklyReport
  alias Youtrack.Workstreams
  alias Youtrack.WorkstreamsLoader
  alias YoutrackWeb.Configuration
  alias YoutrackWeb.ConfigVisibilityPreference
  alias YoutrackWeb.PromptRegistry
  alias YoutrackWeb.RuntimeConfig
  alias YoutrackWeb.WeeklyReportSummary

  @payload_placeholder "{{REPORT_PAYLOAD_JSON}}"

  @issue_fields [
    "idReadable",
    "id",
    "summary",
    "description",
    "created",
    "updated",
    "resolved",
    "project(shortName)",
    "tags(name)",
    "comments(id,text,created,author(name,login))",
    "customFields(name,value(name,login))"
  ]

  @activity_fields [
    "id",
    "timestamp",
    "category(id)",
    "author(name,login)",
    "field(name)",
    "targetMember",
    "added(name)",
    "removed(name)",
    "markup"
  ]

  @impl true
  def mount(_params, _session, socket) do
    defaults =
      Configuration.defaults()
      |> with_report_defaults()
      |> Configuration.merge_shared(Configuration.shared_from_socket(socket))

    prompt_files = PromptRegistry.list_prompt_files(defaults["prompts_path"])
    defaults = ensure_prompt_source(defaults, prompt_files)
    config_open? = ConfigVisibilityPreference.from_socket(socket)

    socket =
      socket
      |> assign(:current_scope, nil)
      |> assign(:page_title, "Weekly Report")
      |> assign(:config_open?, config_open?)
      |> assign(:loading?, false)
      |> assign(:llm_loading?, false)
      |> assign(:fetch_error, nil)
      |> assign(:fetch_cache_state, nil)
      |> assign(:llm_error, nil)
      |> assign(:llm_response, nil)
      |> assign(:active_tab, "summary")
      |> assign(:config, defaults)
      |> assign(:config_form, to_form(defaults, as: :config))
      |> assign(:report_data, nil)
      |> assign(:prompt_files, prompt_files)
      |> assign(:llm_models, [])
      |> assign(:llm_models_loading?, false)
      |> assign(:llm_models_error, nil)
      |> assign(:prompt_preview, nil)

    if connected?(socket) do
      send(self(), :maybe_auto_fetch)
      send(self(), :load_llm_models)
      Phoenix.PubSub.subscribe(YoutrackWeb.PubSub, "workstreams:updated")
      Phoenix.PubSub.subscribe(YoutrackWeb.PubSub, RuntimeConfig.topic())
      Phoenix.PubSub.subscribe(YoutrackWeb.PubSub, PromptRegistry.topic())
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_config", _params, socket) do
    config_open? = !socket.assigns.config_open?

    {:noreply,
     socket
     |> assign(:config_open?, config_open?)
     |> push_event("config_visibility_changed", %{open: config_open?})}
  end

  @impl true
  def handle_event("config_changed", %{"config" => params}, socket) do
    config =
      socket.assigns.config
      |> Configuration.merge_partial(params)

    prompt_files = PromptRegistry.list_prompt_files(config["prompts_path"] || "")
    config = ensure_prompt_source(config, prompt_files)

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:config_form, to_form(config, as: :config))
     |> assign(:prompt_files, prompt_files)}
  end

  @impl true
  def handle_event("refresh_llm_models", _params, socket) do
    {:noreply,
     socket
     |> assign(:llm_models_loading?, true)
     |> assign(:llm_models_error, nil)
     |> start_models_task(socket.assigns.config)}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("build_report", params, socket) do
    refresh? = params["refresh"] == "true"

    case validate_config(socket.assigns.config) do
      :ok ->
        {:noreply,
         socket
         |> assign(:loading?, true)
         |> assign(:fetch_error, nil)
         |> start_report_task(socket.assigns.config, refresh?)}

      {:error, message} ->
        {:noreply, assign(socket, :fetch_error, message)}
    end
  end

  @impl true
  def handle_event("clear_cache", _params, socket) do
    :ok = YoutrackWeb.FetchCache.clear()

    {:noreply,
     socket
     |> assign(:fetch_cache_state, nil)
     |> put_flash(:info, "Cache cleared")}
  end

  @impl true
  def handle_event("reload_config", _params, socket) do
    case Configuration.reload_defaults() do
      {:ok, defaults} ->
        defaults = defaults |> with_report_defaults()
        prompt_files = PromptRegistry.list_prompt_files(defaults["prompts_path"])
        defaults = ensure_prompt_source(defaults, prompt_files)

        {:noreply,
         socket
         |> assign(:config, defaults)
         |> assign(:config_form, to_form(defaults, as: :config))
         |> assign(:prompt_files, prompt_files)
         |> put_flash(:info, "Reloaded .env and workstreams.yaml")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reload failed: #{reason}")}
    end
  end

  @impl true
  def handle_event("generate_prompt", _params, socket) do
    case socket.assigns.report_data do
      nil ->
        {:noreply, assign(socket, :fetch_error, "Build report first")}

      report_data ->
        prompt =
          build_prompt_text(
            load_prompt_template(socket.assigns.config, socket.assigns.prompt_files),
            report_data.report_json
          )

        {:noreply, assign(socket, :prompt_preview, prompt)}
    end
  end

  @impl true
  def handle_event("send_to_llm", _params, socket) do
    cond do
      socket.assigns.report_data == nil ->
        {:noreply, assign(socket, :llm_error, "Build report first")}

      blank?(socket.assigns.config["llm_base_url"]) ->
        {:noreply, assign(socket, :llm_error, "LLM base URL is required")}

      blank?(socket.assigns.config["llm_model"]) ->
        {:noreply, assign(socket, :llm_error, "LLM model is required")}

      true ->
        {:noreply,
         socket
         |> assign(:llm_loading?, true)
         |> assign(:llm_error, nil)
         |> start_llm_task(socket.assigns.config, socket.assigns.report_data)}
    end
  end

  @impl true
  def handle_event("download-weekly-json", _params, socket) do
    case socket.assigns.report_data do
      nil ->
        {:noreply, assign(socket, :fetch_error, "Build report first")}

      report_data ->
        {:noreply,
         push_event(socket, "download_json", %{
           content: report_data.weekly_json,
           filename: "weekly-report.json"
         })}
    end
  end

  @impl true
  def handle_event("download-daily-json", _params, socket) do
    case socket.assigns.report_data do
      nil ->
        {:noreply, assign(socket, :fetch_error, "Build report first")}

      report_data ->
        {:noreply,
         push_event(socket, "download_json", %{
           content: report_data.daily_json,
           filename: "daily-report.json"
         })}
    end
  end

  @impl true
  def handle_event("download-full-json", _params, socket) do
    case socket.assigns.report_data do
      nil ->
        {:noreply, assign(socket, :fetch_error, "Build report first")}

      report_data ->
        {:noreply,
         push_event(socket, "download_json", %{
           content: report_data.report_json,
           filename: "full-report.json"
         })}
    end
  end

  @impl true
  def handle_event("copy-weekly-json", _params, socket), do: copy_json(socket, :weekly)

  @impl true
  def handle_event("copy-daily-json", _params, socket), do: copy_json(socket, :daily)

  @impl true
  def handle_event("copy-full-json", _params, socket), do: copy_json(socket, :full)

  @impl true
  def handle_event("copy-prompt-preview", _params, socket), do: copy_text(socket, :prompt_preview)

  @impl true
  def handle_event("copy-llm-response", _params, socket), do: copy_text(socket, :llm_response)

  @impl true
  def handle_info({ref, {:ok, {:report, report_data}}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:report_data, report_data)
     |> assign(:fetch_cache_state, Map.get(report_data, :fetch_cache_state))
     |> assign(:active_tab, "summary")}
  end

  @impl true
  def handle_info({ref, {:ok, {:llm, content}}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:llm_loading?, false)
     |> assign(:llm_response, content)
     |> assign(:active_tab, "llm")}
  end

  @impl true
  def handle_info({ref, {:ok, {:models, models}}}, socket) do
    Process.demonitor(ref, [:flush])

    config =
      case socket.assigns.config["llm_model"] do
        value when is_binary(value) and value != "" -> socket.assigns.config
        _ -> maybe_set_default_model(socket.assigns.config, models)
      end

    {:noreply,
     socket
     |> assign(:llm_models_loading?, false)
     |> assign(:llm_models_error, nil)
     |> assign(:llm_models, models)
     |> assign(:config, config)
     |> assign(:config_form, to_form(config, as: :config))}
  end

  @impl true
  def handle_info({ref, {:ok, {:models_error, message}}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:llm_models_loading?, false)
     |> assign(:llm_models_error, to_string(message))}
  end

  OLD

  @impl true
  def handle_info({ref, {:error, reason}}, socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:llm_loading?, false)
     |> assign(:fetch_error, to_string(reason))}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:llm_loading?, false)
     |> assign(:fetch_error, "Background task crashed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info(:workstreams_updated, socket) do
    {:noreply,
     socket
     |> assign(:report_data, nil)
     |> put_flash(:info, "Workstream rules updated — re-run fetch to refresh report")}
  end

  @impl true
  def handle_info({:prompts_updated, _payload}, socket) do
    prompt_files = PromptRegistry.list_prompt_files(socket.assigns.config["prompts_path"])
    config = ensure_prompt_source(socket.assigns.config, prompt_files)

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:config_form, to_form(config, as: :config))
     |> assign(:prompt_files, prompt_files)}
  end

  @impl true
  def handle_info({:config_reloaded, payload}, socket) do
    defaults =
      Configuration.defaults()
      |> with_report_defaults()

    config = defaults |> Configuration.merge_partial(socket.assigns.config)
    prompt_files = PromptRegistry.list_prompt_files(config["prompts_path"])
    config = ensure_prompt_source(config, prompt_files)

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:config_form, to_form(config, as: :config))
     |> assign(:prompt_files, prompt_files)
     |> put_flash(:info, config_reload_message(payload[:reason]))}
  end

  @impl true
  def handle_info(:maybe_auto_fetch, socket) do
    cond do
      socket.assigns.loading? ->
        {:noreply, socket}

      socket.assigns.report_data != nil ->
        {:noreply, socket}

      validate_config(socket.assigns.config) != :ok ->
        {:noreply, socket}

      true ->
        {:noreply,
         socket
         |> assign(:loading?, true)
         |> assign(:fetch_error, nil)
         |> start_report_task(socket.assigns.config, false)}
    end
  end

  @impl true
  def handle_info(:load_llm_models, socket) do
    {:noreply,
     socket
     |> assign(:llm_models_loading?, true)
     |> assign(:llm_models_error, nil)
     |> start_models_task(socket.assigns.config)}
  end

  defp start_report_task(socket, config, refresh?) do
    task =
      Task.Supervisor.async_nolink(YoutrackWeb.TaskSupervisor, fn ->
        case build_report(config, refresh?) do
          {:ok, report_data} -> {:ok, {:report, report_data}}
          {:error, reason} -> {:error, reason}
        end
      end)

    assign(socket, :report_task_ref, task.ref)
  end

  defp start_llm_task(socket, config, report_data) do
    task =
      Task.Supervisor.async_nolink(YoutrackWeb.TaskSupervisor, fn ->
        case call_llm(config, report_data) do
          {:ok, content} -> {:ok, {:llm, content}}
          {:error, reason} -> {:error, reason}
        end
      end)

    assign(socket, :llm_task_ref, task.ref)
  end

  defp start_models_task(socket, config) do
    task =
      Task.Supervisor.async_nolink(YoutrackWeb.TaskSupervisor, fn ->
        case fetch_llm_models(config) do
          {:ok, models} -> {:ok, {:models, models}}
          {:error, reason} -> {:ok, {:models_error, reason}}
        end
      end)

    assign(socket, :llm_models_task_ref, task.ref)
  end

  defp build_report(config, refresh?) do
    base_url = config["base_url"] |> to_string() |> String.trim()
    token = config["token"] |> to_string() |> String.trim()
    base_query = config["base_query"] |> to_string() |> String.trim()

    state_field = config["state_field"] |> to_string() |> String.trim()
    assignees_field = config["assignees_field"] |> to_string() |> String.trim()
    project_prefix = config["project_prefix"] |> to_string() |> String.trim()

    include_substreams? = parse_bool(config["include_substreams"])

    week_start = Date.from_iso8601!(config["report_week_start"])
    week_end = Date.from_iso8601!(config["report_week_end"])
    last_working_day = Date.from_iso8601!(config["report_last_working_day"])

    in_progress_names = csv_list(config["in_progress_names"])
    inactive_names = csv_list(config["inactive_states"])
    done_names = csv_list(config["report_done_states"])
    special_tags = csv_list(config["report_special_tags"])
    hold_tags = csv_list(config["report_hold_tags"])
    activities_categories = config["report_activity_categories"] |> to_string() |> String.trim()

    {workstream_rules, _workstreams_path} =
      case config["workstreams_path"] do
        nil ->
          WorkstreamsLoader.load_from_default_paths()

        "" ->
          WorkstreamsLoader.load_from_default_paths()

        path ->
          case WorkstreamsLoader.load_file(path) do
            {:ok, rules} -> {rules, path}
            {:error, _} -> WorkstreamsLoader.load_from_default_paths()
          end
      end

    query =
      "#{base_query} updated: #{Date.to_iso8601(week_start)} .. #{Date.to_iso8601(week_end)}"

    req = Client.new!(base_url, token)
    cache_key = {:weekly_report_issues, base_url, query, @issue_fields}

    {:ok, raw_issues, cache_state} =
      YoutrackWeb.FetchCache.get_or_fetch(
        cache_key,
        fn -> Client.fetch_issues!(req, query, fields: @issue_fields) end,
        refresh: refresh?
      )

    issues = filter_by_project_prefix(raw_issues, project_prefix)

    activity_map =
      issues
      |> Task.async_stream(
        fn issue ->
          acts =
            Client.fetch_activities!(req, issue["id"],
              categories: activities_categories,
              fields: @activity_fields
            )

          {issue["id"], acts}
        end,
        max_concurrency: 8,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce(%{}, fn
        {:ok, {id, acts}}, acc -> Map.put(acc, id, acts)
        _, acc -> acc
      end)

    issue_workstreams =
      issues
      |> Enum.map(fn issue ->
        streams =
          Workstreams.streams_for_issue(issue, workstream_rules,
            include_substreams: include_substreams?
          )
          |> Enum.sort()

        {issue["id"], streams}
      end)
      |> Map.new()

    weekly_start_ms = to_start_ms(week_start)
    weekly_end_ms = to_end_ms(week_end)
    daily_start_ms = to_start_ms(last_working_day)
    daily_end_ms = to_end_ms(last_working_day)

    build_summary = fn issue, window_start_ms, window_end_ms ->
      WeeklyReport.build_issue_summary(
        issue,
        Map.get(activity_map, issue["id"], []),
        state_field: state_field,
        assignees_field: assignees_field,
        in_progress_names: in_progress_names,
        inactive_names: inactive_names,
        done_names: done_names,
        hold_tags: hold_tags,
        special_tags: special_tags,
        workstreams: Map.get(issue_workstreams, issue["id"], []),
        window_start_ms: window_start_ms,
        window_end_ms: window_end_ms
      )
    end

    touched_in_window? = fn issue, summary, window_start_ms, window_end_ms ->
      touched_by_issue_timestamps =
        Enum.any?([issue["created"], issue["updated"], issue["resolved"]], fn ts ->
          is_integer(ts) and ts >= window_start_ms and ts <= window_end_ms
        end)

      touched_by_details =
        summary.description_changes_in_window != [] or
          summary.state_changes_in_window != [] or
          summary.hold_tag_changes_in_window != [] or
          summary.comments_in_window != []

      touched_by_issue_timestamps or touched_by_details
    end

    weekly_summaries =
      issues
      |> Enum.map(&build_summary.(&1, weekly_start_ms, weekly_end_ms))
      |> Enum.filter(fn summary ->
        issue = Enum.find(issues, &((&1["idReadable"] || &1["id"]) == summary.id))
        issue && touched_in_window?.(issue, summary, weekly_start_ms, weekly_end_ms)
      end)

    daily_summaries =
      issues
      |> Enum.map(&build_summary.(&1, daily_start_ms, daily_end_ms))
      |> Enum.filter(fn summary ->
        issue = Enum.find(issues, &((&1["idReadable"] || &1["id"]) == summary.id))
        issue && touched_in_window?.(issue, summary, daily_start_ms, daily_end_ms)
      end)

    weekly_payload = %{
      window: %{start: Date.to_iso8601(week_start), end: Date.to_iso8601(week_end)},
      metrics:
        WeeklyReportSummary.summary_metrics(weekly_summaries, weekly_start_ms, weekly_end_ms),
      issues: weekly_summaries
    }

    daily_payload = %{
      window: %{date: Date.to_iso8601(last_working_day)},
      metrics: WeeklyReportSummary.summary_metrics(daily_summaries, daily_start_ms, daily_end_ms),
      issues: daily_summaries
    }

    report_payload = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      daily_report: daily_payload,
      weekly_report: weekly_payload
    }

    report_json = Jason.encode!(report_payload, pretty: true)

    {:ok,
     %{
       report_payload: report_payload,
       report_json: report_json,
       daily_payload: daily_payload,
       weekly_payload: weekly_payload,
       daily_json: Jason.encode!(daily_payload, pretty: true),
       weekly_json: Jason.encode!(weekly_payload, pretty: true),
       fetch_cache_state: cache_state,
       summary_rows: WeeklyReportSummary.summary_rows(daily_payload, weekly_payload)
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp call_llm(config, report_data) do
    llm_base_url = config["llm_base_url"] |> to_string() |> String.trim_trailing("/")
    llm_model = config["llm_model"] |> to_string() |> String.trim()
    llm_window = (config["llm_window"] || "daily") |> to_string()
    llm_timeout_ms = parse_int(config["llm_timeout_seconds"], 300) * 1000

    selected_payload_json =
      case llm_window do
        "weekly" -> report_data.weekly_json
        "daily" -> report_data.daily_json
        _ -> report_data.report_json
      end

    prompt_template =
      load_prompt_template(config, PromptRegistry.list_prompt_files(config["prompts_path"] || ""))

    prompt_text = build_prompt_text(prompt_template, selected_payload_json)

    case Req.post("#{llm_base_url}/v1/chat/completions",
           headers: llm_headers(config),
           json: %{
             model: llm_model,
             messages: [%{role: "user", content: prompt_text}],
             stream: false
           },
           receive_timeout: llm_timeout_ms
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
        {:ok, content}

      {:ok, %{status: status, body: body}} ->
        {:error,
         "LLM request failed with status #{status}: #{inspect(body) |> String.slice(0, 800)}"}

      {:error, reason} ->
        {:error, "LLM request error: #{inspect(reason)}"}
    end
  end

  defp fetch_llm_models(config) do
    llm_base_url = config["llm_base_url"] |> to_string() |> String.trim_trailing("/")

    if blank?(llm_base_url) do
      {:error, "LLM base URL is required to load models"}
    else
      headers = llm_headers(config)

      case Req.get("#{llm_base_url}/v1/models", headers: headers, receive_timeout: 15_000) do
        {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
          models =
            data
            |> Enum.map(&Map.get(&1, "id"))
            |> Enum.reject(&blank?/1)
            |> Enum.uniq()
            |> Enum.sort()

          if models == [] do
            {:error, "No models returned by provider"}
          else
            {:ok, models}
          end

        {:ok, %{status: status, body: body}} ->
          {:error,
           "Model list request failed with status #{status}: #{inspect(body) |> String.slice(0, 240)}"}

        {:error, reason} ->
          {:error, "Model list request error: #{inspect(reason)}"}
      end
    end
  end

  defp llm_headers(config) do
    api_key = config["llm_api_key"] |> to_string() |> String.trim()

    if api_key == "" do
      []
    else
      [{"authorization", "Bearer #{api_key}"}]
    end
  end

  defp build_prompt_text(prompt_template, payload_json) do
    if String.contains?(prompt_template, @payload_placeholder) do
      String.replace(prompt_template, @payload_placeholder, payload_json)
    else
      prompt_template <> "\n\nJSON payload:\n" <> payload_json
    end
  end

  defp load_prompt_template(config, prompt_files) do
    selected = (config["prompt_source"] || "manual") |> to_string()
    manual = (config["manual_prompt"] || "") |> to_string() |> String.trim()

    cond do
      selected == "manual" and manual != "" ->
        manual

      selected == "manual" ->
        "Write a concise delivery report for leadership. Focus on outcomes, risks, blockers, and notable signals.\n\n#{@payload_placeholder}"

      true ->
        case Enum.find(prompt_files, fn %{id: id} -> id == selected end) do
          nil ->
            "Summarize the report payload.\n\n#{@payload_placeholder}"

          %{path: path} ->
            case File.read(path) do
              {:ok, content} -> content
              {:error, _} -> "Summarize the report payload.\n\n#{@payload_placeholder}"
            end
        end
    end
  end

  defp config_reload_message({:file_change, _paths}),
    do: "Configuration changed on disk and was reloaded"

  defp config_reload_message(:manual), do: "Configuration reloaded"
  defp config_reload_message(_), do: "Configuration updated"

  defp with_report_defaults(defaults) do
    today = Date.utc_today()
    this_week_start = Date.beginning_of_week(today, :monday)
    last_week_start_default = Date.add(this_week_start, -7)
    last_week_end_default = Date.add(this_week_start, -1)

    last_working_day_default =
      case Date.day_of_week(today) do
        1 -> Date.add(today, -3)
        7 -> Date.add(today, -2)
        6 -> Date.add(today, -1)
        _ -> Date.add(today, -1)
      end

    defaults
    |> Map.put_new("report_week_start", Date.to_iso8601(last_week_start_default))
    |> Map.put_new("report_week_end", Date.to_iso8601(last_week_end_default))
    |> Map.put_new("report_last_working_day", Date.to_iso8601(last_working_day_default))
    |> Map.put_new("inactive_states", "To Do, Todo")
    |> Map.put_new("report_done_states", "Done, Won't Do")
    |> Map.put_new("report_special_tags", "on hold, blocked, to be specified")
    |> Map.put_new("report_hold_tags", "on hold, blocked")
    |> Map.put_new(
      "report_activity_categories",
      "CustomFieldCategory,TagsCategory,DescriptionCategory"
    )
    |> Map.put_new("prompt_source", "")
    |> Map.put_new(
      "manual_prompt",
      "Write a concise delivery report for leadership.\n\n#{@payload_placeholder}"
    )
    |> Map.put_new("json_preview_limit", "4000")
    |> Map.put_new("payload_window", "weekly")
    |> Map.put_new("llm_base_url", System.get_env("LLM_BASE_URL", "http://localhost:11434"))
    |> Map.put_new("llm_api_key", System.get_env("LLM_API_KEY", ""))
    |> Map.put_new("llm_model", System.get_env("LLM_MODEL", "qwen2.5:7b"))
    |> Map.put_new("llm_window", "daily")
    |> Map.put_new("llm_timeout_seconds", "300")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_scope}
      config={@config}
      config_form={@config_form}
      config_open?={@config_open?}
      active_section="weekly_report"
      freshness={@fetch_cache_state}
      topbar_label="Weekly Report"
      topbar_hint="Build and preview weekly status reports with LLM assistance."
    >
      <div class="space-y-6 pb-10">
        <div class="metrics-card-strong rounded-[2rem] px-6 py-6 sm:px-8">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p class="metrics-eyebrow text-xs uppercase tracking-[0.28em]">Section</p>
              <h2 class="metrics-brand metrics-title mt-2 text-4xl leading-none">Weekly Report</h2>
              <p class="metrics-copy mt-3">
                Build daily/weekly payloads and generate leadership-ready narrative with optional LLM.
              </p>
            </div>
            <div class="flex gap-2">
              <button
                id="toggle-weekly-config"
                type="button"
                phx-click="toggle_config"
                class="metrics-button metrics-button-secondary"
              >
                {if(@config_open?, do: "Hide config", else: "Show config")}
              </button>
              <button
                id="build-weekly-report"
                type="button"
                phx-click="build_report"
                class="metrics-button metrics-button-primary font-semibold"
              >
                Build (cache)
              </button>
              <button
                id="build-weekly-report-refresh"
                type="button"
                phx-click="build_report"
                phx-value-refresh="true"
                class="metrics-button metrics-button-secondary"
              >
                Rebuild (API)
              </button>
              <button
                id="reload-weekly-config"
                type="button"
                phx-click="reload_config"
                class="metrics-button metrics-button-secondary"
              >
                Reload Configuration
              </button>
              <button
                id="clear-weekly-cache"
                type="button"
                phx-click="clear_cache"
                class="metrics-button metrics-button-ghost"
              >
                Clear cache
              </button>
            </div>
          </div>
          <%= if @fetch_cache_state do %>
            <p id="weekly-cache-state" class="metrics-eyebrow mt-3 text-xs uppercase tracking-[0.2em]">
              Last fetch source: {cache_state_label(@fetch_cache_state)}
            </p>
          <% end %>
        </div>

        <%= if @fetch_error do %>
          <div class="metrics-card rounded-[2rem] border border-red-400/30 bg-red-500/10 p-5 text-red-200">
            {@fetch_error}
          </div>
        <% end %>

        <%= if @config_open? do %>
          <section class="metrics-card rounded-[2rem] p-6">
            <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Configuration</p>
            <.form for={@config_form} id="weekly-config-form" phx-change="config_changed" class="mt-4">
              <div class="grid grid-cols-1 gap-6 xl:grid-cols-2">
                <div class="metrics-subtle-panel rounded-3xl p-4">
                  <p class="metrics-copy text-xs uppercase tracking-[0.22em]">
                    Weekly Payload Options
                  </p>
                  <div class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
                    <.input
                      field={@config_form[:report_week_start]}
                      type="text"
                      label="Week start (ISO)"
                    />
                    <.input field={@config_form[:report_week_end]} type="text" label="Week end (ISO)" />
                    <.input
                      field={@config_form[:report_last_working_day]}
                      type="text"
                      label="Last working day (ISO)"
                    />
                    <.input
                      field={@config_form[:inactive_states]}
                      type="text"
                      label="Inactive states (CSV)"
                    />
                    <.input
                      field={@config_form[:report_done_states]}
                      type="text"
                      label="Done states (CSV)"
                    />
                    <.input
                      field={@config_form[:report_special_tags]}
                      type="text"
                      label="Special tags (CSV)"
                    />
                    <.input
                      field={@config_form[:report_hold_tags]}
                      type="text"
                      label="Hold tags (CSV)"
                    />
                    <.input
                      field={@config_form[:report_activity_categories]}
                      type="text"
                      label="Activity categories"
                    />
                    <.input
                      field={@config_form[:payload_window]}
                      type="select"
                      label="Payload window"
                      options={[{"Daily", "daily"}, {"Weekly", "weekly"}, {"Full", "full"}]}
                    />
                    <.input
                      field={@config_form[:json_preview_limit]}
                      type="number"
                      label="JSON preview limit"
                    />
                  </div>
                </div>

                <div class="metrics-subtle-panel rounded-3xl p-4">
                  <p class="metrics-eyebrow text-xs uppercase tracking-[0.22em]">Send to LLM</p>
                  <div class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
                    <.input
                      field={@config_form[:prompt_source]}
                      type="select"
                      label="Prompt source"
                      options={prompt_source_options(@prompt_files)}
                    />

                    <div class="md:col-span-2">
                      <div class="metrics-subtle-panel flex items-center justify-between gap-3 rounded-2xl px-3 py-2">
                        <p class="metrics-title text-sm">Available models</p>
                        <button
                          id="refresh-llm-models"
                          type="button"
                          phx-click="refresh_llm_models"
                          class="metrics-button metrics-button-ghost px-3 py-2 text-xs"
                        >
                          Refresh list
                        </button>
                      </div>
                      <%= if @llm_models_loading? do %>
                        <p class="metrics-copy mt-2 text-xs">Loading models from provider...</p>
                      <% end %>
                      <%= if @llm_models_error do %>
                        <p class="metrics-error-copy mt-2 text-xs">{@llm_models_error}</p>
                      <% end %>
                    </div>

                    <.input field={@config_form[:llm_base_url]} type="text" label="LLM base URL" />
                    <.input field={@config_form[:llm_api_key]} type="password" label="LLM API key" />
                    <.input
                      field={@config_form[:llm_model]}
                      type="select"
                      label="LLM model"
                      options={llm_model_options(@llm_models, @config["llm_model"])}
                    />
                    <.input
                      field={@config_form[:llm_window]}
                      type="select"
                      label="LLM payload window"
                      options={[{"Daily", "daily"}, {"Weekly", "weekly"}, {"Full", "full"}]}
                    />
                    <.input
                      field={@config_form[:llm_timeout_seconds]}
                      type="number"
                      label="LLM timeout seconds"
                    />

                    <%= if @config["prompt_source"] == "manual" do %>
                      <div class="md:col-span-2">
                        <.input
                          field={@config_form[:manual_prompt]}
                          type="textarea"
                          rows="16"
                          label="Manual prompt"
                        />
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            </.form>
          </section>
        <% end %>

        <%= if @loading? do %>
          <div class="metrics-card metrics-copy rounded-4xl p-8">
            Building report payload from issues and activities...
          </div>
        <% end %>

        <%= if @report_data do %>
          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              phx-click="select_tab"
              phx-value-tab="summary"
              class={tab_class(@active_tab == "summary")}
            >
              Summary
            </button>
            <button
              type="button"
              phx-click="select_tab"
              phx-value-tab="json"
              class={tab_class(@active_tab == "json")}
            >
              JSON Preview
            </button>
            <button
              type="button"
              phx-click="select_tab"
              phx-value-tab="payload"
              class={tab_class(@active_tab == "payload")}
            >
              Payload Tree
            </button>
            <button
              type="button"
              phx-click="select_tab"
              phx-value-tab="copy"
              class={tab_class(@active_tab == "copy")}
            >
              Copy/Download
            </button>
            <button
              type="button"
              phx-click="select_tab"
              phx-value-tab="llm"
              class={tab_class(@active_tab == "llm")}
            >
              LLM
            </button>
          </div>

          <%= if @active_tab == "summary" do %>
            <section class="metrics-card rounded-4xl p-6">
              <h3 class="metrics-title text-xl font-semibold">Report Summary</h3>
              <div class="mt-4 overflow-x-auto">
                <table class="metrics-table min-w-full text-sm">
                  <thead>
                    <tr class="border-b">
                      <th class="px-3 py-2 text-left">Window</th>
                      <th class="px-3 py-2 text-left">Issues touched</th>
                      <th class="px-3 py-2 text-left">Completed</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for row <- @report_data.summary_rows do %>
                      <tr class="border-b">
                        <td class="px-3 py-2">{row.window}</td>
                        <td class="px-3 py-2">{row.issues}</td>
                        <td class="px-3 py-2">{row.completed}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>

              <div class="mt-6 grid gap-4 md:grid-cols-2">
                <div class="metrics-subtle-panel rounded-2xl p-4">
                  <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Daily issues</p>
                  <div class="mt-3 flex flex-wrap gap-2">
                    <%= for issue <- payload_issues(@report_data, :daily_payload) do %>
                      <.link
                        id={"weekly-daily-card-#{issue.id}"}
                        navigate={~p"/card/#{issue.id}"}
                        class="metrics-pill metrics-pill-accent px-2 py-1 text-[11px]"
                      >
                        {issue.id}
                      </.link>
                    <% end %>
                  </div>
                </div>

                <div class="metrics-subtle-panel rounded-2xl p-4">
                  <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Weekly issues</p>
                  <div class="mt-3 flex flex-wrap gap-2">
                    <%= for issue <- payload_issues(@report_data, :weekly_payload) do %>
                      <.link
                        id={"weekly-weekly-card-#{issue.id}"}
                        navigate={~p"/card/#{issue.id}"}
                        class="metrics-pill metrics-pill-accent px-2 py-1 text-[11px]"
                      >
                        {issue.id}
                      </.link>
                    <% end %>
                  </div>
                </div>
              </div>
            </section>
          <% end %>

          <%= if @active_tab == "json" do %>
            <section class="metrics-card rounded-4xl p-6">
              <h3 class="metrics-title text-xl font-semibold">JSON Preview</h3>
              <div class="metrics-code metrics-code-panel mt-4 overflow-x-auto rounded-3xl p-4 text-xs">
                <pre>{truncate(@report_data.report_json, parse_int(@config["json_preview_limit"], 4000))}</pre>
              </div>
            </section>
          <% end %>

          <%= if @active_tab == "payload" do %>
            <section class="metrics-card rounded-4xl p-6 space-y-6">
              <div>
                <h3 class="metrics-title text-xl font-semibold">Weekly Payload</h3>
                <div class="metrics-code metrics-code-panel mt-3 overflow-x-auto rounded-3xl p-4 text-xs">
                  <pre>{truncate(@report_data.weekly_json, 3000)}</pre>
                </div>
              </div>
              <div>
                <h3 class="metrics-title text-xl font-semibold">Daily Payload</h3>
                <div class="metrics-code metrics-code-panel mt-3 overflow-x-auto rounded-3xl p-4 text-xs">
                  <pre>{truncate(@report_data.daily_json, 3000)}</pre>
                </div>
              </div>
            </section>
          <% end %>

          <%= if @active_tab == "copy" do %>
            <section id="download-section" phx-hook=".DownloadJson" class="metrics-card rounded-4xl p-6 space-y-4">
              <h3 class="metrics-title text-xl font-semibold">Copy / Download</h3>
              <div class="grid gap-4 md:grid-cols-3">
                <div class="metrics-subtle-panel rounded-2xl p-4 space-y-3">
                  <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Daily</p>
                  <button
                    id="copy-daily-json"
                    type="button"
                    phx-click="copy-daily-json"
                    class="metrics-button metrics-button-ghost w-full text-sm"
                  >
                    Copy daily JSON
                  </button>
                  <button
                    id="download-daily-json"
                    type="button"
                    phx-click="download-daily-json"
                    class="metrics-button metrics-button-ghost w-full text-sm"
                  >
                    Download daily JSON
                  </button>
                </div>
                <div class="metrics-subtle-panel rounded-2xl p-4 space-y-3">
                  <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Weekly</p>
                  <button
                    id="copy-weekly-json"
                    type="button"
                    phx-click="copy-weekly-json"
                    class="metrics-button metrics-button-ghost w-full text-sm"
                  >
                    Copy weekly JSON
                  </button>
                  <button
                    id="download-weekly-json"
                    type="button"
                    phx-click="download-weekly-json"
                    class="metrics-button metrics-button-ghost w-full text-sm"
                  >
                    Download weekly JSON
                  </button>
                </div>
                <div class="metrics-subtle-panel rounded-2xl p-4 space-y-3">
                  <p class="metrics-copy text-xs uppercase tracking-[0.24em]">Full</p>
                  <button
                    id="copy-full-json"
                    type="button"
                    phx-click="copy-full-json"
                    class="metrics-button metrics-button-ghost w-full text-sm"
                  >
                    Copy full JSON
                  </button>
                  <button
                    id="download-full-json"
                    type="button"
                    phx-click="download-full-json"
                    class="metrics-button metrics-button-ghost w-full text-sm"
                  >
                    Download full JSON
                  </button>
                </div>
              </div>
            </section>
          <% end %>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".DownloadJson">
            export default {
              mounted() {
                this.handleEvent('download_json', (data) => {
                  this.downloadJson(data.content, data.filename);
                });

                this.handleEvent('copy_json', (data) => {
                  this.copyJson(data.content);
                });
              },
              downloadJson(content, filename) {
                const blob = new Blob([content], { type: 'application/json;charset=utf-8' });
                const url = URL.createObjectURL(blob);
                const link = document.createElement('a');
                link.href = url;
                link.download = filename;
                document.body.appendChild(link);
                link.click();
                document.body.removeChild(link);
                URL.revokeObjectURL(url);
              },
              async copyJson(content) {
                if (navigator.clipboard?.writeText) {
                  await navigator.clipboard.writeText(content);
                  this.showCopiedNotice();
                  return;
                }

                const textarea = document.createElement('textarea');
                textarea.value = content;
                textarea.setAttribute('readonly', '');
                textarea.style.position = 'absolute';
                textarea.style.left = '-9999px';
                document.body.appendChild(textarea);
                textarea.select();
                document.execCommand('copy');
                document.body.removeChild(textarea);
                this.showCopiedNotice();
              },
              showCopiedNotice() {
                const existing = document.getElementById('weekly-copy-toast');
                if (existing) {
                  existing.remove();
                }

                const toast = document.createElement('div');
                toast.id = 'weekly-copy-toast';
                toast.textContent = 'Copied';
                toast.className = 'fixed bottom-6 right-6 z-50 rounded-xl bg-[color:var(--metrics-surface)] px-4 py-2 text-sm font-semibold shadow-lg border border-[color:color-mix(in_oklab,var(--metrics-text)_18%,transparent)]';
                document.body.appendChild(toast);

                window.setTimeout(() => {
                  const current = document.getElementById('weekly-copy-toast');
                  if (current) {
                    current.remove();
                  }
                }, 1400);
              }
            }
          </script>

          <%= if @active_tab == "llm" do %>
            <section id="weekly-llm-section" phx-hook=".DownloadJson" class="metrics-card rounded-4xl p-6 space-y-4">
              <h3 class="metrics-title text-xl font-semibold">LLM Summary</h3>
              <div class="flex gap-2">
                <button
                  id="generate-prompt"
                  type="button"
                  phx-click="generate_prompt"
                  class="metrics-button metrics-button-ghost text-sm"
                >
                  Generate prompt
                </button>
                <button
                  id="send-to-llm"
                  type="button"
                  phx-click="send_to_llm"
                  class="metrics-button metrics-button-primary text-sm font-semibold"
                >
                  Send to LLM
                </button>
              </div>

              <%= if @llm_loading? do %>
                <p class="metrics-copy">Calling LLM endpoint...</p>
              <% end %>

              <%= if @llm_error do %>
                <p class="metrics-error-copy">{@llm_error}</p>
              <% end %>

              <%= if @prompt_preview do %>
                <div class="flex justify-end">
                  <button
                    id="copy-prompt-preview"
                    type="button"
                    phx-click="copy-prompt-preview"
                    class="metrics-button metrics-button-ghost text-sm"
                  >
                    Copy prompt + JSON
                  </button>
                </div>
                <div class="metrics-code metrics-code-panel overflow-x-auto rounded-3xl p-4 text-xs">
                  <pre>{@prompt_preview}</pre>
                </div>
              <% end %>

              <%= if @llm_response do %>
                <div class="flex justify-end">
                  <button
                    id="copy-llm-response"
                    type="button"
                    phx-click="copy-llm-response"
                    class="metrics-button metrics-button-ghost text-sm"
                  >
                    Copy LLM response
                  </button>
                </div>
                <div class="metrics-success-panel rounded-2xl p-4 text-sm">
                  <pre>{@llm_response}</pre>
                </div>
              <% end %>
            </section>
          <% end %>
        <% end %>
      </div>
    </Layouts.dashboard>
    """
  end

  defp prompt_source_options(prompt_files) do
    file_options = Enum.map(prompt_files, fn file -> {file.label, file.id} end)
    file_options ++ [{"Manual prompt", "manual"}]
  end

  defp llm_model_options(models, selected_model) do
    selected_option =
      case selected_model do
        value when is_binary(value) and value != "" -> [{value, value}]
        _ -> []
      end

    discovered = Enum.map(models, fn model -> {model, model} end)

    (selected_option ++ discovered)
    |> Enum.uniq()
  end

  defp ensure_prompt_source(config, prompt_files) do
    selected = config["prompt_source"] |> to_string()
    prompt_ids = Enum.map(prompt_files, & &1.id)

    cond do
      selected == "manual" -> config
      selected in prompt_ids -> config
      prompt_files == [] -> Map.put(config, "prompt_source", "manual")
      true -> Map.put(config, "prompt_source", default_prompt_source(prompt_files))
    end
  end

  defp default_prompt_source(prompt_files) do
    case Enum.find(prompt_files, &String.starts_with?(&1.label, ".prompt")) do
      nil -> List.first(prompt_files).id
      prompt_file -> prompt_file.id
    end
  end

  defp maybe_set_default_model(config, []), do: config
  defp maybe_set_default_model(config, [first | _]), do: Map.put(config, "llm_model", first)

  defp tab_class(active?) do
    base = "rounded-lg border px-3 py-2 text-sm"

    if active? do
      base <> " metrics-tab-active"
    else
      base <> " metrics-tab-idle"
    end
  end

  defp cache_state_label(:hit), do: "cache hit"
  defp cache_state_label(:miss), do: "cache miss"
  defp cache_state_label(:refresh), do: "refresh"
  defp cache_state_label(%{source: source}), do: cache_state_label(source)
  defp cache_state_label(_), do: "unknown"

  defp truncate(text, max_chars) when is_binary(text) and is_integer(max_chars) do
    if String.length(text) <= max_chars do
      text
    else
      String.slice(text, 0, max_chars) <> "\n\n... (truncated)"
    end
  end

  defp payload_issues(report_data, payload_key) do
    report_data
    |> Map.get(payload_key, %{})
    |> Map.get(:issues, [])
    |> Enum.map(fn summary -> %{id: summary.id} end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  defp to_start_ms(date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp to_end_ms(date) do
    date
    |> Date.add(1)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix(:millisecond)
    |> Kernel.-(1)
  end

  defp filter_by_project_prefix(issues, ""), do: issues

  defp filter_by_project_prefix(issues, prefix) do
    Enum.filter(issues, fn issue -> String.starts_with?(issue["idReadable"] || "", prefix) end)
  end

  defp copy_json(socket, variant) do
    case socket.assigns.report_data do
      nil ->
        {:noreply, assign(socket, :fetch_error, "Build report first")}

      report_data ->
        {:noreply,
         push_event(socket, "copy_json", %{content: report_json_variant(report_data, variant)})}
    end
  end

  defp copy_text(socket, key) do
    case Map.get(socket.assigns, key) do
      value when is_binary(value) and value != "" ->
        {:noreply, push_event(socket, "copy_json", %{content: value})}

      _ ->
        {:noreply, assign(socket, :fetch_error, "Nothing to copy yet")}
    end
  end

  defp report_json_variant(report_data, :daily), do: report_data.daily_json
  defp report_json_variant(report_data, :weekly), do: report_data.weekly_json
  defp report_json_variant(report_data, :full), do: report_data.report_json

  defp csv_list(nil), do: []

  defp csv_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_bool(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp parse_bool(_), do: false

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp validate_config(config) do
    cond do
      blank?(config["base_url"]) -> {:error, "Base URL is required"}
      blank?(config["token"]) -> {:error, "Token is required"}
      blank?(config["base_query"]) -> {:error, "Base query is required"}
      blank?(config["report_week_start"]) -> {:error, "Week start is required"}
      blank?(config["report_week_end"]) -> {:error, "Week end is required"}
      blank?(config["report_last_working_day"]) -> {:error, "Last working day is required"}
      true -> :ok
    end
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
