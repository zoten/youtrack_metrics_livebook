defmodule YoutrackWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use YoutrackWeb, :html

  alias Phoenix.LiveView.JS

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"
  )

  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <div class="app-frame">
      <main class="app-main">
        {render_slot(@inner_block)}
      </main>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"
  )

  attr(:config, :map, required: true)
  attr(:active_section, :string, default: nil)
  attr(:freshness, :any, default: nil)
  attr(:topbar_label, :string, default: "Interface")
  attr(:topbar_hint, :string, default: "Light, dark, or system theme applies across every route.")

  slot(:inner_block, required: true)

  def dashboard(assigns) do
    ~H"""
    <.app flash={@flash} current_scope={@current_scope}>
      <div class="metrics-shell">
        <.metrics_sidebar
          config={@config}
          active_section={@active_section}
          freshness={@freshness}
        />

        <section class="metrics-content">
          <div class="metrics-topbar">
            <div>
              <p class="metrics-topbar-label">{@topbar_label}</p>
              <p class="text-sm text-(--metrics-muted)">{@topbar_hint}</p>
            </div>

            <div class="flex items-center gap-3">
              <span class="metrics-topbar-label">Theme</span>
              <.theme_toggle />
            </div>
          </div>

          {render_slot(@inner_block)}
        </section>
      </div>
    </.app>
    """
  end

  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      class="metrics-theme-toggle"
      data-active-theme="system"
      role="group"
      aria-label="Theme switcher"
    >
      <button
        id="theme-system"
        type="button"
        class="metrics-theme-toggle-button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
        aria-pressed="true"
      >
        <.icon name="hero-computer-desktop" class="size-4" />
      </button>
      <button
        id="theme-light"
        type="button"
        class="metrics-theme-toggle-button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
        aria-pressed="false"
      >
        <.icon name="hero-sun" class="size-4" />
      </button>
      <button
        id="theme-dark"
        type="button"
        class="metrics-theme-toggle-button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
        aria-pressed="false"
      >
        <.icon name="hero-moon" class="size-4" />
      </button>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
