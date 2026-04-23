// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { hooks as colocatedHooks } from "phoenix-colocated/youtrack_web"
import topbar from "../vendor/topbar"

// Import custom hooks
import VegaLite from "./hooks"

const CONFIG_OPEN_STORAGE_KEY = "youtrack.config_open"
const THEME_STORAGE_KEY = "phx:theme"
const SHARED_CONFIG_STORAGE_KEY = "youtrack.shared_config"
const CARD_TIMELINE_FILTERS_STORAGE_KEY = "youtrack.card_timeline_filters"

const readConfigOpenPreference = () => {
  try {
    const value = window.localStorage.getItem(CONFIG_OPEN_STORAGE_KEY)

    if (value === "true" || value === "false") {
      return value
    }

    return null
  } catch (_error) {
    return null
  }
}

const writeConfigOpenPreference = (isOpen) => {
  try {
    window.localStorage.setItem(CONFIG_OPEN_STORAGE_KEY, `${isOpen}`)
  } catch (_error) {
    // Ignore storage errors (for example privacy mode restrictions).
  }
}

const readSharedConfigPreference = () => {
  try {
    const raw = window.localStorage.getItem(SHARED_CONFIG_STORAGE_KEY)

    if (!raw) {
      return {}
    }

    const parsed = JSON.parse(raw)

    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed
      : {}
  } catch (_error) {
    return {}
  }
}

const writeSharedConfigPreference = (value) => {
  try {
    window.localStorage.setItem(SHARED_CONFIG_STORAGE_KEY, JSON.stringify(value || {}))
  } catch (_error) {
    // Ignore storage errors (for example privacy mode restrictions).
  }
}

const readCardTimelineFiltersPreference = () => {
  try {
    const raw = window.localStorage.getItem(CARD_TIMELINE_FILTERS_STORAGE_KEY)

    if (!raw) {
      return { exclude_todo: false, exclude_no_sprint: false }
    }

    const parsed = JSON.parse(raw)

    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return { exclude_todo: false, exclude_no_sprint: false }
    }

    return {
      exclude_todo: parsed.exclude_todo === true,
      exclude_no_sprint: parsed.exclude_no_sprint === true,
    }
  } catch (_error) {
    return { exclude_todo: false, exclude_no_sprint: false }
  }
}

const writeCardTimelineFiltersPreference = (value) => {
  try {
    window.localStorage.setItem(
      CARD_TIMELINE_FILTERS_STORAGE_KEY,
      JSON.stringify({
        exclude_todo: value?.exclude_todo === true,
        exclude_no_sprint: value?.exclude_no_sprint === true,
      }),
    )
  } catch (_error) {
    // Ignore storage errors (for example privacy mode restrictions).
  }
}

const sharedConfigFromForm = (form) => {
  const result = {}
  const formData = new FormData(form)

  formData.forEach((value, key) => {
    const match = key.match(/^config\[(.+)\]$/)

    if (match && typeof value === "string") {
      result[match[1]] = value
    }
  })

  return result
}

const SharedConfigBridge = {
  mounted() {
    this.persist = () => {
      writeSharedConfigPreference(sharedConfigFromForm(this.el))
    }

    this.el.addEventListener("input", this.persist)
    this.el.addEventListener("change", this.persist)

    this.persist()
  },

  updated() {
    this.persist()
  },

  destroyed() {
    this.el.removeEventListener("input", this.persist)
    this.el.removeEventListener("change", this.persist)
  },
}

const normalizeThemePreference = (value) => {
  if (value === "light" || value === "dark") {
    return value
  }

  return "system"
}

const readThemePreference = () => {
  try {
    return normalizeThemePreference(window.localStorage.getItem(THEME_STORAGE_KEY))
  } catch (_error) {
    return "system"
  }
}

const readResolvedTheme = () => {
  if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
    return "dark"
  }

  return "light"
}

const applyThemePreference = (theme) => {
  const resolvedTheme = theme === "system" ? readResolvedTheme() : theme

  // Always set data-theme explicitly so the DaisyUI token selector wins
  // over any @media (prefers-color-scheme) rules in the cascade.
  document.documentElement.setAttribute("data-theme", resolvedTheme)

  document.documentElement.dataset.activeTheme = theme
  document.documentElement.dataset.resolvedTheme = resolvedTheme

  const toggle = document.getElementById("theme-toggle")

  if (toggle) {
    toggle.dataset.activeTheme = theme
  }

  document
    .querySelectorAll("[data-phx-theme]")
    .forEach((button) => button.setAttribute("aria-pressed", `${button.dataset.phxTheme === theme}`))
}

const writeThemePreference = (theme) => {
  try {
    if (theme === "system") {
      window.localStorage.removeItem(THEME_STORAGE_KEY)
    } else {
      window.localStorage.setItem(THEME_STORAGE_KEY, theme)
    }
  } catch (_error) {
    // Ignore storage errors (for example privacy mode restrictions).
  }
}

const setThemePreference = (theme) => {
  const normalizedTheme = normalizeThemePreference(theme)

  writeThemePreference(normalizedTheme)
  applyThemePreference(normalizedTheme)
}

const colorSchemeQuery = window.matchMedia("(prefers-color-scheme: dark)")

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({
    _csrf_token: csrfToken,
    config_open: readConfigOpenPreference(),
    shared_config: readSharedConfigPreference(),
    card_timeline_filters: readCardTimelineFiltersPreference(),
  }),
  hooks: { VegaLite, SharedConfigBridge, ...colocatedHooks },
})

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" })
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())
window.addEventListener("phx:config_visibility_changed", event => {
  const isOpen = event?.detail?.open

  if (typeof isOpen === "boolean") {
    writeConfigOpenPreference(isOpen)
  }
})
window.addEventListener("phx:card_timeline_filters_changed", event => {
  writeCardTimelineFiltersPreference(event?.detail)
})

applyThemePreference(readThemePreference())

window.addEventListener("storage", event => {
  if (event.key === THEME_STORAGE_KEY) {
    applyThemePreference(normalizeThemePreference(event.newValue))
  }
})

window.addEventListener("phx:set-theme", event => {
  const theme = event.target?.dataset?.phxTheme || event.detail?.theme

  if (theme) {
    setThemePreference(theme)
  }
})

colorSchemeQuery.addEventListener("change", () => {
  if (readThemePreference() === "system") {
    applyThemePreference("system")
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if (keyDown === "c") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if (keyDown === "d") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

