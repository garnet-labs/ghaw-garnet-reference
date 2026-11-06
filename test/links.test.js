const test = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const { join } = require("node:path")

const readme = readFileSync(join(__dirname, "..", "README.md"), "utf8")
const links = [...new Set(readme.match(/https?:\/\/[^\s)>`"]+/g))]
    .map((url) => url.replace(/[.,;:]+$/, ""))
    .filter((url) => !url.includes("#"))

test("README has external links", () => {
    assert.ok(links.length > 0)
})

for (const url of links) {
    test(`README link responds: ${url}`, async () => {
        const response = await fetch(url, { method: "HEAD", redirect: "follow", signal: AbortSignal.timeout(10_000) })
        assert.ok(response.status < 400 || response.status === 405, `${url} returned ${response.status}`)
    })
}
