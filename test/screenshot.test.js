const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const puppeteer = require("puppeteer")

function readmeToHtml(markdown) {
    const escape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    const body = markdown
        .split("\n")
        .filter((line) => line.trim() !== "")
        .map((line) => {
            const heading = /^(#{1,6})\s+(.*)$/.exec(line)
            if (heading) return `<h${heading[1].length}>${escape(heading[2])}</h${heading[1].length}>`
            return `<p>${escape(line)}</p>`
        })
        .join("\n")
    return `<!doctype html><html><body>${body}</body></html>`
}

test("README renders with an <h1> in a headless browser", async () => {
    const markdown = fs.readFileSync(path.join(__dirname, "..", "README.md"), "utf8")
    const browser = await puppeteer.launch({ channel: "chrome" })
    try {
        const page = await browser.newPage()
        await page.setContent(readmeToHtml(markdown))
        const h1 = await page.$eval("h1", (el) => el.textContent)
        assert.equal(h1, "ghaw-garnet-reference")
    } finally {
        await browser.close()
    }
})
