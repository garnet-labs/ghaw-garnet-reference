const test = require("node:test")
const assert = require("node:assert/strict")
const { execFileSync } = require("node:child_process")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")

const script = path.join(__dirname, "..", "scripts", "backfill_domains_from_report.sh")

// `gh run view --log` prefixes every line with the job and step name.
const runLog = [
    "test\tRun npm ci\tadded 1 package in 2s",
    "test\tPost Record this job with Garnet\tNETWORK EGRESS SUMMARY",
    "test\tPost Record this job with Garnet\tDestination           Count",
    "test\tPost Record this job with Garnet\tregistry.npmjs.org    3",
    "test\tPost Record this job with Garnet\tlocalhost             1",
    "test\tPost Record this job with Garnet\t10.1.0.4              2",
    "test\tPost Record this job with Garnet\tlodash 4.17.21        1",
    "test\tPost Record this job with Garnet\tNetwork Telemetry Summary",
    "",
].join("\n")

function writeStub(dir, name, body) {
    const file = path.join(dir, name)
    fs.writeFileSync(file, `#!/bin/sh\n${body}\n`)
    fs.chmodSync(file, 0o755)
}

test("run log backfill reports hostnames only, not log words, counts, versions or IPs", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "backfill-domains-"))
    const bin = path.join(tmp, "bin")
    const out = path.join(tmp, "out")
    fs.mkdirSync(bin)
    fs.writeFileSync(path.join(tmp, "run.log"), runLog)
    writeStub(bin, "curl", "exit 22")
    writeStub(bin, "gh", `cat '${path.join(tmp, "run.log")}'`)

    execFileSync("bash", [script, out], {
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, GITHUB_RUN_ID: "123", GITHUB_REPOSITORY: "o/r" },
        stdio: ["ignore", "ignore", "ignore"],
    })

    const domains = fs.readFileSync(path.join(out, "domains_for_run.list.txt"), "utf8").trim().split("\n")
    assert.deepEqual(domains, ["localhost", "registry.npmjs.org"])
    const summary = fs.readFileSync(path.join(out, "domains_for_run.txt"), "utf8")
    assert.match(summary, /^domains_source=garnet_runtime_report$/m)
    assert.match(summary, /^domains_found=2$/m)
})
