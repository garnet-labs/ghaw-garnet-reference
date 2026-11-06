const test = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const { join } = require("node:path")

// Offline by default: `npm test` runs on every pull request and must not
// depend on seven external hosts answering. Set LINK_CHECK=1 (a scheduled
// job, or a local run) to also send a HEAD request to each link.
const liveCheck = process.env.LINK_CHECK === "1"

const readme = readFileSync(join(__dirname, "..", "README.md"), "utf8")
const links = [...new Set(readme.match(/https?:\/\/[^\s)>`"]+/g))]
    .map((url) => url.replace(/[.,;:]+$/, ""))
    .filter((url) => !url.includes("#"))

test("README has external links", () => {
    assert.ok(links.length > 0)
})

for (const url of links) {
    test(`README link is well-formed: ${url}`, () => {
        const parsed = new URL(url)
        assert.equal(parsed.protocol, "https:", `${url} is not https`)
        assert.ok(!["localhost", "127.0.0.1"].includes(parsed.hostname), `${url} points at a local host`)
    })

    test(`README link responds: ${url}`, { skip: !liveCheck && "set LINK_CHECK=1 to send HEAD requests" }, async () => {
        const response = await fetch(url, { method: "HEAD", redirect: "follow", signal: AbortSignal.timeout(10_000) })
        assert.ok(response.status < 400 || response.status === 405, `${url} returned ${response.status}`)
    })
}
