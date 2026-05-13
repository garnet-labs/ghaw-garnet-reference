# Required secrets

This repo's workflows need two secrets to run.

## `GARNET_API_TOKEN`

The token Garnet's action uses to register the run and stream events to your tenant.

1. Sign in to [dashboard.garnet.ai](https://dashboard.garnet.ai).
2. **Settings → API Tokens → New token**.
3. Name it after the repo (e.g. `acme/ci-monitor`) so you can revoke it later.
4. Copy the token — you won't see it again.
5. In the repo: **Settings → Secrets and variables → Actions → New repository secret**. Name: `GARNET_API_TOKEN`. Value: the token.

## `ANTHROPIC_API_KEY`

Both example workflows use `engine: claude`, which calls Anthropic's API for the LLM.

1. [console.anthropic.com](https://console.anthropic.com/settings/keys) → Create Key.
2. Add it as a repo secret named `ANTHROPIC_API_KEY`.

> Using a different engine? Swap `engine: claude` → `engine: codex` (or copilot) in the workflow `.md` files and provide the corresponding key (`OPENAI_API_KEY`, etc.). Re-run `gh aw compile`.

## Org-wide rollout

To instrument many repos, add both as **organization secrets** instead and scope them to selected repositories. Each repo's workflows pick them up without further config.

## Rotation

Both tokens are revocable. If a token leaks:

1. Revoke immediately at the source (dashboard.garnet.ai for Garnet, console.anthropic.com for Anthropic).
2. Mint a new one.
3. Update the GitHub secret.

In-flight runs continue using the old token until completion; new runs pick up the new value.
