const test = require("node:test")
const assert = require("node:assert/strict")
const puppeteer = require("puppeteer-core")

// puppeteer-core drives the Chrome already on the runner image instead of
// downloading one at install time; override the path with PUPPETEER_EXECUTABLE_PATH.
const executablePath = process.env.PUPPETEER_EXECUTABLE_PATH || "/usr/bin/google-chrome"

// The runner's Chrome is a stock build: without these flags it contacts
// accounts.google.com, clients.l.google.com, www.google.com and www.gstatic.com
// on launch (sign-in, component updates, safe browsing). The test needs none of it.
const args = [
    "--no-sandbox",
    "--no-first-run",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-sync",
    "--disable-default-apps",
    "--disable-features=OptimizationHints,MediaRouter,Translate,SafeBrowsing",
]

test("a headless browser renders a page", async () => {
    const browser = await puppeteer.launch({ executablePath, args })
    try {
        const page = await browser.newPage()
        await page.setContent("<h1>Dependency Runtime Review</h1>")
        assert.equal(await page.$eval("h1", (h) => h.textContent), "Dependency Runtime Review")
    } finally {
        await browser.close()
    }
})
