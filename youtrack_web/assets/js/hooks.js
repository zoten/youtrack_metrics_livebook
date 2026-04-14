import * as vegaEmbed from 'vega-embed'

const resolvedVegaTheme = () => {
    const resolved = document.documentElement.dataset.resolvedTheme
    return resolved === "light" ? undefined : "dark"
}

export default {
    mounted() {
        console.log(`[VegaLite Hook] mounted for chart #${this.el.id}`)
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

        // Re-render when the card/container resizes (e.g. sidebar toggle, window resize).
        this._resizeObserver = new ResizeObserver(() => this.render())
        this._resizeObserver.observe(this.el)
    },

    destroyed() {
        if (this._themeObserver) {
            this._themeObserver.disconnect()
        }
        if (this._resizeObserver) {
            this._resizeObserver.disconnect()
        }
    },

    updated() {
        this.render()
    },

    render() {
        console.log(`[VegaLite Hook] render called for chart #${this.el.id}`)
        const spec = this.el.getAttribute("data-spec")
        if (!spec) {
            console.warn(`[VegaLite Hook] No data-spec attribute on #${this.el.id}`)
            return
        }

        try {
            console.log(`[VegaLite Hook] Parsing spec for #${this.el.id}`)
            const specObj = JSON.parse(spec)
            const schema = specObj.$schema || ""
            const isVegaLite = schema.includes("vega-lite")

            console.log(`[VegaLite Hook] Schema: ${schema}, isVegaLite: ${isVegaLite}`)

            // Force responsive width for Vega-Lite specs so charts fill their container.
            // Full Vega specs may use absolute coordinates, so keep their authored width.
            if (isVegaLite) {
                if (specObj.spec && (specObj.facet || specObj.repeat)) {
                    specObj.spec.width = "container"
                } else if (Array.isArray(specObj.vconcat)) {
                    specObj.vconcat.forEach(sub => { sub.width = "container" })
                } else {
                    specObj.width = "container"
                }
            }
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

            console.log(`[VegaLite Hook] Calling vegaEmbed for #${this.el.id}`)
            vegaEmbed.default(this.el, specObj, options)
                .then(_result => {
                    console.log(`[VegaLite Hook] Successfully rendered chart #${this.el.id}`)
                })
                .catch(error => {
                    console.error(`[VegaLite Hook] Error rendering chart #${this.el.id}:`, error)
                    this.el.innerHTML = `<div class="text-red-500 p-4">Error rendering chart: ${error.message}</div>`
                })
        } catch (error) {
            console.error(`[VegaLite Hook] JSON parse error for #${this.el.id}:`, error)
            this.el.innerHTML = `<div class="text-red-500 p-4">Invalid chart specification</div>`
        }
    }
}
