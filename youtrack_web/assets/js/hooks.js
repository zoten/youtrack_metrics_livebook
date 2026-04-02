import * as vegaEmbed from 'vega-embed'

const resolvedVegaTheme = () => {
    const resolved = document.documentElement.dataset.resolvedTheme
    return resolved === "light" ? undefined : "dark"
}

export default {
    mounted() {
        this.render()
        this.handleEvent("update_spec", _data => this.render())

        // Re-render charts when theme changes so the vega-embed background
        // follows the page theme.
        this._themeObserver = new MutationObserver((mutations) => {
            for (const m of mutations) {
                if (m.attributeName === "data-resolved-theme") {
                    this.render()
                    break
                }
            }
        })
        this._themeObserver.observe(document.documentElement, { attributes: true })
    },

    destroyed() {
        if (this._themeObserver) {
            this._themeObserver.disconnect()
        }
    },

    updated() {
        this.render()
    },

    render() {
        const spec = this.el.getAttribute("data-spec")
        if (!spec) {
            console.warn("No data-spec attribute found on chart element")
            return
        }

        try {
            const specObj = JSON.parse(spec)
            // Force responsive width so charts fill their container instead of using
            // the hardcoded pixel widths from the Elixir spec generators.
            specObj.width = "container"
            if (specObj.autosize == null) {
                specObj.autosize = { type: "fit", contains: "padding" }
            }
            const options = {
                actions: {
                    export: true,
                    source: false,
                    compiled: false,
                    editor: false
                },
                hover: true,
                theme: resolvedVegaTheme()
            }

            vegaEmbed.default(this.el, specObj, options)
                .then(_result => { })
                .catch(error => {
                    console.error("Error rendering Vega-Lite spec:", error)
                    this.el.innerHTML = `<div class="text-red-500 p-4">Error rendering chart: ${error.message}</div>`
                })
        } catch (error) {
            console.error("Invalid JSON spec:", error)
            this.el.innerHTML = `<div class="text-red-500 p-4">Invalid chart specification</div>`
        }
    }
}
