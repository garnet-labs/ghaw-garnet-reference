const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const script = path.join(__dirname, "..", "scripts", "backfill_domains_from_report.sh")

test("backfill fetches the full public report URL and reads its domains", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "backfill-"))
    const bin = path.join(dir, "bin")
    const out = path.join(dir, "out")
    const calls = path.join(dir, "curl-calls.txt")
    fs.mkdirSync(bin)
    fs.writeFileSync(
        path.join(bin, "curl"),
        `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "${calls}"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then printf 'node -> registry.npmjs.org\\n' > "$2"; fi
  shift
done
`,
        { mode: 0o755 },
    )

    execFileSync("bash", [script, out], {
        env: {
            PATH: `${bin}:${process.env.PATH}`,
            GITHUB_RUN_ID: "123",
            GITHUB_REPOSITORY: "garnet-labs/ghaw-garnet-reference",
        },
        stdio: "pipe",
    })

    const firstCall = fs.readFileSync(calls, "utf8").split("\n")[0]
    assert.equal(
        firstCall,
        `-fsS https://dashboard.garnet.ai/public/runs/123/report.md -o ${out}/public_run_report.md`,
    )
    assert.match(fs.readFileSync(path.join(out, "domains_for_run.txt"), "utf8"), /domains_source=garnet_public_report/)
    assert.match(fs.readFileSync(path.join(out, "domains_for_run.md"), "utf8"), /- registry\.npmjs\.org/)
})
