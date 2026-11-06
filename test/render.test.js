const test = require("node:test")
const assert = require("node:assert/strict")
const puppeteer = require("puppeteer")

test("a headless browser renders a page", async () => {
    const browser = await puppeteer.launch({ args: ["--no-sandbox"] })
    try {
        const page = await browser.newPage()
        await page.setContent("<h1>Dependency Runtime Review</h1>")
        assert.equal(await page.$eval("h1", (h) => h.textContent), "Dependency Runtime Review")
    } finally {
        await browser.close()
    }
})
