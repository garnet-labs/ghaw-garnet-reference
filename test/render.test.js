const test = require("node:test")
const assert = require("node:assert/strict")
const puppeteer = require("puppeteer-core")

// puppeteer-core drives the Chrome already on the runner image instead of
// downloading one at install time; override the path with PUPPETEER_EXECUTABLE_PATH.
const executablePath = process.env.PUPPETEER_EXECUTABLE_PATH || "/usr/bin/google-chrome"

test("a headless browser renders a page", async () => {
    const browser = await puppeteer.launch({ executablePath, args: ["--no-sandbox"] })
    try {
        const page = await browser.newPage()
        await page.setContent("<h1>Dependency Runtime Review</h1>")
        assert.equal(await page.$eval("h1", (h) => h.textContent), "Dependency Runtime Review")
    } finally {
        await browser.close()
    }
})
