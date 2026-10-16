# 80/20 Health: notes for Claude Code

Personal iOS app (SwiftUI, SwiftData + CloudKit, HealthKit, Oura API v2). One user: the owner, on TestFlight. Design: `docs/ARCHITECTURE.md`. Mac-only setup runbook: `docs/LOCAL_SETUP.md`.

## Working from a cloud session (no Mac, no Xcode)

- **GitHub Actions is the compiler.** Every push to `main` or `claude/**` that touches code runs `.github/workflows/ios.yml`: core package tests, then a signed archive uploaded to TestFlight (build number = 100 + run number). Docs-only pushes (`**.md`, `docs/**`) skip it.
- **After pushing, watch the run** and fix it if it fails; don't hand back a red build:
  ```sh
  R=mrellcrane/eightytwentyhealth
  RUN=$(gh api "repos/$R/actions/runs?branch=$(git branch --show-current)&per_page=1" -q '.workflow_runs[0].id')
  gh api repos/$R/actions/runs/$RUN -q '.status + " " + (.conclusion // "")'
  gh api repos/$R/actions/runs/$RUN/jobs -q '.jobs[].steps[] | select(.conclusion=="failure") | .name'
  ```
  `gh pr`/`gh issue` (GraphQL) don't work through the cloud proxy; use `gh api` (REST). `gh auth status` reports the token as invalid; ignore it, `gh api` still works.
- **Signing:** each run makes a throwaway "Created via API" development certificate; the next run revokes the old ones before archiving (Apple caps how many an account holds). If an archive fails with "maximum number of certificates", check that step's output.
- **Job logs:** `gh api .../actions/jobs/<id>/logs` fails with `Forbidden`, because GitHub redirects log downloads to `*.blob.core.windows.net`, which the cloud network policy blocks. Read logs with the GitHub MCP tool `get_job_logs` instead (`job_id`, `return_content: true`, `tail_lines` ~150 reaches the `Uploaded build N` line).
- **Core logic is plain Swift** in `Packages/EightyTwentyCore` (no UIKit/HealthKit), with tests. If `swift` is installed (environment setup script; the default cloud image doesn't have it, and then CI is the only test run), run `cd Packages/EightyTwentyCore && swift test` before pushing. Put new logic there, with tests, whenever it doesn't need Apple frameworks.
- **App code** (`App/`) only compiles in CI. Keep changes there small and match the surrounding style.
- A finished build reaches the owner's phone through TestFlight about 15 minutes after the run goes green. Tell them the build number.

## Seeing what happens on the phone: Sentry

The app sends its log lines and errors to Sentry (`App/Shared/Log.swift`). Use them to find and confirm bugs before changing code.

- `Log.<category>.info / warning / error("...")`. Categories: app, oura, sync, health, backup, meditation. `error` also opens a Sentry issue.
- **Never log health values, tokens, notes, or anything the user wrote.** Status codes, counts, endpoint names and error descriptions are fine.
- Environments: `debug` (Xcode builds), `testflight`, `production`.
- TestFlight crashes and hangs show function names only if CI uploaded that build's dSYMs, which needs the `SENTRY_AUTH_TOKEN` Actions secret (a Sentry organization auth token). Xcode builds don't upload them.

Querying (org and project come from the environment; the auth token is either `$SENTRY_AUTH_TOKEN` or injected for sentry.io by the environment's network secret). The network secret must be scoped to the path `/api/0/` (zero, not the letter o); otherwise every call returns 401 `Authentication credentials were not provided.` If a `jq` below fails with `Cannot iterate over null` or `Cannot index string`, the API returned an error object: rerun without `jq` to read it.

```sh
S=https://sentry.io/api/0
AUTH=(); [ -n "$SENTRY_AUTH_TOKEN" ] && AUTH=(-H "Authorization: Bearer $SENTRY_AUTH_TOKEN")

# Unresolved issues, last 7 days (the per-project endpoint only accepts statsPeriod 24h or 14d)
curl -s "${AUTH[@]}" -G "$S/organizations/$SENTRY_ORG/issues/" \
  --data-urlencode "query=is:unresolved project:$SENTRY_PROJECT" --data-urlencode statsPeriod=7d \
  | jq -r '.[] | "\(.id)  \(.count)x  last \(.lastSeen)  \(.title)"'

# Latest event of an issue (message, tags, device, release)
curl -s "${AUTH[@]}" "$S/organizations/$SENTRY_ORG/issues/<ISSUE_ID>/events/latest/" \
  | jq '{message: .message, tags: .tags, release: .release.version}'

# Recent log lines (all levels), newest first
curl -s "${AUTH[@]}" -G "$S/organizations/$SENTRY_ORG/events/" \
  --data-urlencode dataset=ourlogs --data-urlencode statsPeriod=24h \
  --data-urlencode field=timestamp --data-urlencode field=severity \
  --data-urlencode field=category --data-urlencode field=message \
  --data-urlencode sort=-timestamp --data-urlencode per_page=100 \
  | jq -r '.data[] | "\(.timestamp)  \(.severity)  [\(.category)]  \(.message)"'
```

Filter logs with `--data-urlencode query='severity:error'` or `query='category:oura'`. When a fix ships, check the next TestFlight build's logs to confirm it.

## Conventions

- Branch: work on the session's `claude/...` branch; never push to `main` directly.
- Secrets live in `Config/Secrets.xcconfig` (gitignored) locally and in GitHub Actions secrets in CI. Never commit them. The repo is public.
- xcconfig values can't contain `//`, which is why `SENTRY_DSN` is stored without `https://`.
- Oura scopes must match Oura's spec exactly (`spo2`, not `spo2Daily`); a 401 that names a scope is `OuraError.missingScope`, not a dead sign-in.
