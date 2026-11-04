---
name: Agentic Custom Package Install (Garnet-Monitored)
description: >
  Runs a Claude agent under Garnet/Jibril eBPF monitoring that installs one or
  more npm packages and writes a smoke test for each. Captures install-time
  AND runtime behavior — postinstall scripts, unexpected egress, file writes
  outside the workdir — at the kernel level, from outside the agent's
  container.

  This is the "package-installing agent, highest value" pattern from the
  Garnet resources guide.

on:
  workflow_dispatch:
    inputs:
      packages:
        description: "Comma-separated list (e.g. left-pad@1.3.0, lodash@4.17.21)"
        required: false
        default: "left-pad@1.3.0"

permissions:
  contents: read
  id-token: write         # required by garnet-org/action for OIDC

engine:
  id: claude

timeout-minutes: 25

network:
  allowed:
    - defaults
    - node                # registry.npmjs.org + npm mirrors
    - github
    - api.garnet.ai
    - dashboard.garnet.ai

steps:
  - name: Start Garnet Agent
    id: garnet
    uses: garnet-org/action@v2.4.1
    with:
      api_token: ${{ secrets.GARNET_API_TOKEN }}

  - name: Setup Node.js
    uses: actions/setup-node@v4
    with:
      node-version: "20"

  - name: Stage workspace for package install
    env:
      PACKAGES_INPUT: ${{ inputs.packages }}
    run: |
      mkdir -p /tmp/gh-aw/pkg-install
      printf '%s\n' "${PACKAGES_INPUT}" > /tmp/gh-aw/pkg-install/packages.txt
      echo "--- packages.txt ---"
      cat /tmp/gh-aw/pkg-install/packages.txt

      # Workaround for ERR_SSL_PACKET_LENGTH_TOO_LONG when npm inside the gh-aw
      # container talks to registry.npmjs.org through the awf squid proxy.
      # Explicit proxy/https-proxy entries force npm into a proper HTTP CONNECT
      # tunnel so it TLS-handshakes end-to-end with the registry.
      #
      # IMPORTANT: scope this .npmrc to the workdir ONLY. Writing it to
      # /home/runner/.npmrc breaks the host runner's own npm bootstrap because
      # 172.30.0.10 is the awf bridge gateway and is unreachable from the host
      # network namespace. The agent does `cd /tmp/gh-aw/pkg-install` before
      # invoking npm, so npm picks up this file from cwd automatically.
      printf '%s\n' \
        'registry=https://registry.npmjs.org/' \
        'proxy=http://172.30.0.10:3128/' \
        'https-proxy=http://172.30.0.10:3128/' \
        'strict-ssl=true' \
        'fetch-retries=2' \
        'fetch-retry-mintimeout=2000' \
        'fetch-retry-maxtimeout=15000' \
        > /tmp/gh-aw/pkg-install/.npmrc

tools:
  bash:
    - "npm init *"
    - "npm install *"
    - "npm ls *"
    - "node *"
    - "cat *"
    - "ls *"
    - "find *"
    - "jq *"
    - "echo *"
  edit:
  github:
    toolsets: [context]

safe-outputs:
  create-issue:
    title-prefix: "[pkg-install] "
    labels: [garnet, pkg-install, automated]
    max: 1
---

# Custom NPM Package Install Agent

You are a developer evaluating candidate npm packages under Garnet/Jibril
eBPF monitoring. Install each package one at a time and write a short smoke
test for each. Every syscall and network connection is observed at the
kernel level, from outside this container.

## Inputs

The comma-separated package list is in `/tmp/gh-aw/pkg-install/packages.txt`.
Read it with `cat`, split on commas, trim whitespace.

## Setup

1. `cd /tmp/gh-aw/pkg-install`
2. `npm init -y`

## For each package in `packages.txt` (in order)

a) **Install** — `npm install <pkg>@<exact-version>`.
b) **Inspect** — `cat node_modules/<name>/package.json` to find the `main`
   entry and any exports.
c) **Test** — write `test-<safe-name>.js` that `require()`s the package and
   exercises one export.
d) **Run** — `node test-<safe-name>.js` and capture stdout + exit code.
e) **Record** — on any failure (install or test), log the full error and
   continue to the next package. Do not abort.

## Output

Open a single GitHub issue summarizing, per package:

- Install OK? (yes/no, exit code)
- Test OK? (yes/no, exit code)
- First 20 lines of test stdout
- Any error message verbatim
- A 3-line "behavioral note" — anything unusual the package did at install
  or first-require time. Garnet's runtime trace will be reviewed separately,
  so be honest about what you observed from the shell only.

### Issue title

`[pkg-install] Run <github.run_id> — <N> packages tested`

## Important

- Install packages one at a time, in the order given. Never batch.
- Do not run `npm audit fix` or modify lockfiles globally.
- Do not pull additional packages beyond what is in `packages.txt`.
- If a package's `postinstall` script fails, that is data — record it, do
  not retry.
