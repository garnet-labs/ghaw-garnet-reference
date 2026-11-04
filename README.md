# ghaw-garnet-reference

> Reference implementation: instrument [GitHub Agentic Workflows (gh-aw)](https://github.com/githubnext/gh-aw) with [Garnet](https://garnet.ai) for kernel-level visibility from **outside the agent's security boundary**.

This is the companion repo to the Garnet resources guide [**Instrumenting GitHub Agentic Workflows with Garnet**](https://garnet.ai/resources/instrument-github-agentic-workflows-with-garnet). It contains three working workflows: the current **Dependency Runtime Review** path (tokenless, gh-aw v1.0 GA) and two older agent workflows from the guide that still use repository secrets. Start with the first one.

## Dependency Runtime Review (gh-aw v1.0 GA, no tokens)

GitHub shows you what files changed in a PR. Garnet shows you what changed at runtime when CI ran it. [`dependency-runtime-review.md`](.github/workflows/dependency-runtime-review.md) connects the two for dependency changes: when a pull request touches `package.json` or `package-lock.json`, the ordinary Garnet-recorded [`CI`](.github/workflows/ci.yml) job installs and tests the new tree, and an agentic workflow reads the Garnet record for that PR (the Garnet App's head-bound PR comment, with the Garnet MCP at `https://api.garnet.ai/api/v2/mcp` for per-job profiles) and posts one comment naming which changed package is behind each new outbound connection, plus one label (`runtime-changed`, `runtime-nothing-new`, `runtime-capture-incomplete`).

```
pull_request (paths: package.json, lockfiles)
  ├─ CI / test ─────── checkout → garnet-org/action@v2 (OIDC) → npm ci → npm test     recorded by Garnet
  └─ agent (gh-aw) ─── PR diff + Garnet App comment (GitHub tool) → Garnet MCP profiles (optional, per job)
       └─ safe-outputs: add-comment (replaces its previous comment) + add-labels
```

### See it on a real pull request

[PR #10](https://github.com/garnet-labs/ghaw-garnet-reference/pull/10) adds `puppeteer` as a devDependency. Garnet recorded a new destination on that bump (`node` now reaches `storage.googleapis[.]com`, the Chrome download in Puppeteer's install script); the agent (an earlier version of this workflow, which read the record through the superseded hosted MCP) read that record and posted a [dependency-specific review](https://github.com/garnet-labs/ghaw-garnet-reference/pull/10#issuecomment-6618514847) plus the `runtime-changed` label ([agent run](https://github.com/garnet-labs/ghaw-garnet-reference/actions/runs/41741836647)). [PR #3](https://github.com/garnet-labs/ghaw-garnet-reference/pull/3), a Dependabot patch bump, shows the quiet case: nothing new recorded, capture incomplete, so the agent says the behavior is unknown and labels `runtime-capture-incomplete` rather than calling it clean. This is an internal reference run by Garnet, not a report from someone else's repository.

### Use it in your repository

No repository secrets are involved. Three settings, all on GitHub:

1. Install the [Garnet GitHub App](https://github.com/apps/garnet-runtime-review) on the repository. It posts the Runtime Review comment that the agent reads.
2. Record your ordinary CI job. Give it `id-token: write` and make Garnet its first step (see [`ci.yml`](.github/workflows/ci.yml)):

   ```yaml
   permissions:
     contents: read
     id-token: write
   steps:
     - uses: actions/checkout@v7
     - uses: garnet-org/action@673a06d87748bec49e4d8df22d371b2a3420aba4 # v2.5.2
     - run: npm ci && npm test
   ```

3. Let the agent bill Copilot to your organization: Organization settings → Copilot → Policies → Copilot CLI → "Allow use of Copilot CLI billed to the organization". The workflow asks for it with `permissions: copilot-requests: write`.

Then copy [`dependency-runtime-review.md`](.github/workflows/dependency-runtime-review.md) into `.github/workflows/`, run `gh aw compile dependency-runtime-review`, commit the `.md` and the generated `.lock.yml`, and create the three labels (`runtime-changed`, `runtime-nothing-new`, `runtime-capture-incomplete`). The next pull request that touches `package.json` or `package-lock.json` gets the comment and label.

### How it is put together

- gh-aw primitives: `on.pull_request` with `paths`/`bots`/`reaction`, `mcp-servers` (HTTP, `allowed` tools), `network.allowed`, `tools.bash` allowlist, `safe-outputs` (`add-comment`, `add-labels`), automatic threat detection, SHA-pinned actions via `.github/aw/actions-lock.json`.
- The agent counts the record only when it is bound to the PR's current head; an incomplete or missing capture is unknown, never clean. Observed names are quoted as untrusted data.
- Garnet authenticates with GitHub OIDC (`id-token: write`); no `GARNET_API_TOKEN` is used. The Copilot engine runs on the repository's own Actions token with `copilot-requests: write`; no engine secret is used. The model is pinned to `gpt-4.1` because gh-aw's cost proxy currently has no pricing entry for the model `auto` resolves to. Without org billing, set a `COPILOT_GITHUB_TOKEN` fine-grained PAT (Copilot Requests: Read) as a repository secret and change the permission to `copilot-requests: none`.
- Reviewer grounding: `.coderabbit.yaml`, `.pr_agent.toml`, `greptile.json`, `REVIEW.md`, `.agents/skills/garnet-runtime-review/SKILL.md` are vendored byte-for-byte from garnet-runtime-review-mcp `examples/reviewers/`.
- Recompile with `gh aw compile .github/workflows/dependency-runtime-review.md` after editing the source; never edit the lock.

## What's in here

```
.github/workflows/
  ci.yml                        # Ordinary CI, recorded by Garnet (OIDC, no token)
  dependency-runtime-review.md  # Agent that reads the Garnet record of a dependency PR (Copilot, org-billed)
  dependency-runtime-review.lock.yml

  # Older workflows from the guide (claude engine, repository secrets):
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

## Older workflows: quick start (10 minutes)

Everything below this line is about `daily-repo-status` and `agentic-pkg-install`, the two workflows from the original guide. They run the agent on the Claude engine and pass a Garnet project token, so unlike Dependency Runtime Review they need repository secrets. Skip this section if you only want the dependency review.

### 1. Required secrets

In **Settings → Secrets and variables → Actions**:

| Secret | Source |
|---|---|
| `GARNET_API_TOKEN` | [dashboard.garnet.ai](https://dashboard.garnet.ai) → Settings → API Tokens (these two workflows pass it as `api_token`; the Dependency Runtime Review path uses OIDC instead) |
| `ANTHROPIC_API_KEY` | [console.anthropic.com](https://console.anthropic.com/settings/keys) (Claude engine) |

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

If you're porting your own agent workflow (the agent job itself recorded, as in the two older workflows) rather than recording ordinary CI:

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
    # with: api_token is only needed without the Garnet GitHub App + OIDC;
    # the two older workflows here still pass it.

# 4. (Production) pin to the release SHA (current: v2.5.2, see https://garnet.ai/pins)
#    uses: garnet-org/action@673a06d87748bec49e4d8df22d371b2a3420aba4  # v2.5.2
```

Then run `gh aw compile` and commit both the `.md` and `.lock.yml`.

## Verified versions

| Component | Version |
|---|---|
| `garnet-org/action` | `v2.5.2` = `673a06d87748bec49e4d8df22d371b2a3420aba4` (current release; `ci.yml` follows the `v2` tag). The two older `.lock.yml` files pin the same SHA. |
| `jibril_version` | Action default (`v2.17.0` at v2.5.2) for `ci.yml`; the two older workflows pin `2.12.0` |
| `gh-aw` CLI | `v1.0.1` for `dependency-runtime-review`; `v0.72.1` for the two older locks |
| `gh-aw` runtime (awf) | `0.29.0` / `0.25.41` respectively |
| Runner image | `ubuntu-latest` (22.04, 24.04 verified) |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: Resource not accessible by integration` on Garnet step | `id-token: write` missing | Add it under `permissions:` |
| `dial tcp: lookup api.garnet.ai: no such host` or 403 from Garnet API | `network:` shorthand still in use, or `api.garnet.ai` not in allow-list | Use the structured `network.allowed:` form |
| Run completes but dashboard.garnet.ai shows nothing | Garnet step isn't first, or (older workflows) `GARNET_API_TOKEN` is wrong | Move it to position 1; re-verify the secret name |
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
