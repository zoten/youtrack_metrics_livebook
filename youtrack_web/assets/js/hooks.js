import * as vegaEmbed from 'vega-embed'

export default {
    mounted() {
        this.render()
        this.handleEvent("update_spec", data => this.render())
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
            const options = {
                actions: {
                    export: true,
                    source: false,
                    compiled: false,
                    editor: false
                },
                hover: true,
                theme: this.el.getAttribute("data-theme") || "dark"
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
