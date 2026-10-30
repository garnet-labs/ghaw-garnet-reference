# ghaw-garnet-reference

> Reference implementation: instrument [GitHub Agentic Workflows (gh-aw)](https://github.com/githubnext/gh-aw) with [Garnet](https://garnet.ai) for kernel-level visibility from **outside the agent's security boundary**.

This is the companion repo to the Garnet resources guide [**Instrumenting GitHub Agentic Workflows with Garnet**](https://garnet.ai/resources/instrument-github-agentic-workflows-with-garnet). It contains two working, opinionated workflows you can fork or copy into your own repo.

## New: Dependency Runtime Review (gh-aw v1.0 GA)

GitHub shows you what files changed in a PR. Garnet shows you what changed at runtime when CI ran it. [`dependency-runtime-review.md`](.github/workflows/dependency-runtime-review.md) connects the two for dependency changes: when a pull request touches `package.json` or a lockfile, the ordinary Garnet-recorded [`CI`](.github/workflows/ci.yml) job installs and tests the new tree, and an agentic workflow reads the Garnet record for that PR through the hosted [Runtime Review MCP](https://github.com/garnet-labs/garnet-runtime-review-mcp) and posts one comment naming which changed package is behind each new outbound connection, plus one label (`runtime-changed`, `runtime-nothing-new`, `runtime-capture-incomplete`).

```
pull_request (paths: package.json, lockfiles)
  ├─ CI / test ─────── checkout → garnet-org/action@v2 (OIDC) → npm ci → npm test     recorded by Garnet
  └─ agent (gh-aw) ─── git diff → get_runtime_review / get_execution_profile (MCP)
       └─ safe-outputs: add-comment (replaces its previous comment) + add-labels
```

- gh-aw primitives: `on.pull_request` with `paths`/`bots`/`reaction`, `mcp-servers` (HTTP, `allowed` tools), `network.allowed`, `tools.bash` allowlist, `safe-outputs` (`add-comment`, `add-labels`), automatic threat detection, SHA-pinned actions via `.github/aw/actions-lock.json`.
- The agent counts the record only when it is bound to the PR's current head; an incomplete or missing capture is unknown, never clean. Observed names are quoted as untrusted data.
- Garnet authenticates with GitHub OIDC (`id-token: write`); no `GARNET_API_TOKEN` is needed for this workflow. The Copilot engine uses `permissions: copilot-requests: write` (inference billed to the org, no PAT); set `COPILOT_GITHUB_TOKEN` instead if your org lacks centralized Copilot billing.
- Reviewer grounding: `.coderabbit.yaml`, `.pr_agent.toml`, `greptile.json`, `REVIEW.md`, `.agents/skills/garnet-runtime-review/SKILL.md` are vendored byte-for-byte from garnet-runtime-review-mcp `examples/reviewers/`.
- Recompile with `gh aw compile .github/workflows/dependency-runtime-review.md` after editing the source; never edit the lock.

## What's in here

```
.github/workflows/
  daily-repo-status.md          # Scheduled agent, low blast radius — use this to validate Garnet
  daily-repo-status.lock.yml    #   (compiled by `gh aw compile`)
  agentic-pkg-install.md        # Package-installing agent, high value — kernel sees postinstall
  agentic-pkg-install.lock.yml  #   (compiled by `gh aw compile`)

scripts/
  garnet_snapshot.sh                # Captures run-scoped Garnet artifacts to .garnet/runtime/latest/
  backfill_domains_from_report.sh   # Fallback: re-fetch domains from the public runtime report
```

## Why outside the boundary

GitHub's [security architecture for gh-aw](https://github.blog/ai-and-ml/generative-ai/under-the-hood-security-architecture-of-github-agentic-workflows/) (Landon Cox) puts the agent in a container with a chroot jail rooted at `/host`, on a private network, behind a firewall and API proxy. Secrets, the runner VM, and `Linux /proc state` live **outside** that boundary.

Garnet's eBPF runtime, [Jibril](https://jibril.garnet.ai/), loads on the runner VM — outside the agent's container. It sees every syscall the agent makes, every outbound flow with full process ancestry, every file the agent touches. The agent cannot disable it; it doesn't hold a token for that privilege domain.

This repo is the minimum viable setup for getting there.

## Quick start (10 minutes)

### 1. Required secrets

In **Settings → Secrets and variables → Actions**:

| Secret | Source |
|---|---|
| `GARNET_API_TOKEN` | [dashboard.garnet.ai](https://dashboard.garnet.ai) → Settings → API Tokens |
| `ANTHROPIC_API_KEY` | [console.anthropic.com](https://console.anthropic.com/settings/keys) |

See [`SECRETS.md`](./SECRETS.md) for details and org-secret rollout.

### 2. Trigger the scheduled agent to validate the integration

```bash
gh workflow run daily-repo-status.lock.yml
gh run watch
```

Within ~30 seconds of the `Start Garnet Agent` step finishing, the run shows up in [dashboard.garnet.ai](https://dashboard.garnet.ai) under **Recent Runs**. You should see:

- **Flows** — outbound connections (`api.github.com`, `api.anthropic.com`)
- **Profile** — process ancestry rooted at `Runner.Worker`
- **Detections** — empty (this agent doesn't do anything suspicious)

If any of those are missing, see [Troubleshooting](#troubleshooting) below.

### 3. Trigger the package-installing agent to see the value

```bash
gh workflow run agentic-pkg-install.lock.yml -f packages="left-pad@1.3.0, lodash@4.17.21"
```

In the dashboard, the run's **Flows** will now include `registry.npmjs.org` and whatever the package's `postinstall` scripts reached. The **Profile** will show `bash → npm → node → …` chains. This is what you can't get from text logs.

## The four edits that turn a stock gh-aw workflow into a Garnet-instrumented one

If you're porting your own workflow rather than starting from this one:

```yaml
# 1. permissions must include id-token: write (Garnet OIDC)
permissions:
  contents: read
  id-token: write

# 2. network must be the structured form with Garnet endpoints
network:
  allowed:
    - defaults
    - github
    - api.garnet.ai
    - dashboard.garnet.ai

# 3. Garnet must be the FIRST step in the top-level steps: block
steps:
  - name: Start Garnet Agent
    id: garnet
    uses: garnet-org/action@v2
    with:
      api_token: ${{ secrets.GARNET_API_TOKEN }}
      jibril_version: "2.12.0"

# 4. (Production) pin to a verified SHA
#    uses: garnet-org/action@3d47f4a9004f7356c980a0e8d420ef5984750e3c  # v2
```

Then run `gh aw compile` and commit both the `.md` and `.lock.yml`.

## Verified versions

| Component | Version |
|---|---|
| `garnet-org/action` | `v2` → SHA `3d47f4a9004f7356c980a0e8d420ef5984750e3c` (auto-pinned by `gh aw compile`) |
| `jibril_version` | `2.12.0` |
| `gh-aw` CLI | `v0.72.1` |
| `gh-aw` runtime (awf) | `v0.25.41` |
| Runner image | `ubuntu-latest` (22.04, 24.04 verified) |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: Resource not accessible by integration` on Garnet step | `id-token: write` missing | Add it under `permissions:` |
| `dial tcp: lookup api.garnet.ai: no such host` or 403 from Garnet API | `network:` shorthand still in use, or `api.garnet.ai` not in allow-list | Use the structured `network.allowed:` form |
| Run completes but dashboard.garnet.ai shows nothing | Garnet step isn't first, or `GARNET_API_TOKEN` is wrong | Move it to position 1; re-verify the secret name |
| `npm ERR! … ERR_SSL_PACKET_LENGTH_TOO_LONG` during install | gh-aw squid proxy + npm TLS mismatch | See the `.npmrc` workaround in [`agentic-pkg-install.md`](./.github/workflows/agentic-pkg-install.md) |
| `.lock.yml` out of sync warning in Actions | Edited `.md` without recompiling | `gh aw compile`, commit both files |

## Optional: capture a run-scoped snapshot artifact

For offline-reviewable evidence per run (audits, downstream analysis), add a post-agent step that calls `./scripts/garnet_snapshot.sh ./.garnet/runtime/latest` and uploads `.garnet/runtime/latest/` as an artifact. See the [resources guide](https://garnet.ai/resources/instrument-github-agentic-workflows-with-garnet) for the exact YAML.

## Further reading

- [Instrumenting GitHub Agentic Workflows with Garnet](https://garnet.ai/resources/instrument-github-agentic-workflows-with-garnet) — the full practitioner guide
- [Under the hood: Security architecture of GitHub Agentic Workflows](https://github.blog/ai-and-ml/generative-ai/under-the-hood-security-architecture-of-github-agentic-workflows/) — Landon Cox on the substrate model
- [Jibril security model](https://jibril.garnet.ai/jibril/readme/jibril)
- [`githubnext/gh-aw`](https://github.com/githubnext/gh-aw) and the [`githubnext/agentics` workflow catalog](https://github.com/githubnext/agentics/tree/main/workflows)

## License

MIT. See [LICENSE](./LICENSE).
