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
  `gh pr`/`gh issue` (GraphQL) don't work through the cloud proxy; use `gh api` (REST). `gh auth status` reports the token as invalid; ignore it, `gh api` still works. The repo is public, so unauthenticated `curl https://api.github.com/repos/mrellcrane/eightytwentyhealth/actions/runs/<id>` works too.
- **Signing:** each run makes a throwaway "Created via API" development certificate; the next run revokes the old ones before archiving (Apple caps how many an account holds). If an archive fails with "maximum number of certificates", check that step's output.
- **Job logs:** `gh api .../actions/jobs/<id>/logs` fails with `Forbidden`, because GitHub redirects log downloads to `*.blob.core.windows.net`, which the cloud network policy blocks. Read logs with the GitHub MCP tool `get_job_logs` instead (`job_id`, `return_content: true`, `tail_lines` ~150 reaches the `Uploaded build N` line).
- **Several sessions build this app at once, each on its own `claude/...` branch, and every push uploads a TestFlight build.** The owner's phone runs whichever build landed last, so a branch that's missing another branch's work makes that work vanish. Before starting, `git fetch origin` and check the other recent `claude/...` branches (`git branch -r --sort=-committerdate`); merge in what's needed so your builds don't regress theirs. A push to a branch cancels that branch's running CI build (`cancel-in-progress`).
- **Core logic is plain Swift** in `Packages/EightyTwentyCore` (no UIKit/HealthKit), with tests. Run them before pushing. Put new logic there, with tests, whenever it doesn't need Apple frameworks. If `swift` is installed, `cd Packages/EightyTwentyCore && swift test`. If not (the default cloud image doesn't have it; swift.org downloads are blocked, Docker Hub works), use the `swift:6.1` image; the CA mount lets the container through the session's TLS proxy:
  ```sh
  (sudo dockerd > /tmp/dockerd.log 2>&1 &); sleep 5; docker pull swift:6.1
  cd Packages/EightyTwentyCore && docker run --rm --network host -e CLAUDE_COACH_API_KEY \
    -v /root/.ccr/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro \
    -v swiftbuild:/tmp/build -v "$PWD":/pkg -w /pkg swift:6.1 swift test --scratch-path /tmp/build
  ```
- **Coach live tests**: `CoachLiveTests` calls the real Claude API: the owner's 1 PM scenario (both answers printed) and a study lookup on meditation followed by a library match (`--filter CoachLiveTests`). They run only when `CLAUDE_COACH_API_KEY` is set (cloud sessions; never `ANTHROPIC_API_KEY`, which Claude Code itself may read), and are skipped in CI. Never print or write the key. Run them after any change to the coach's system prompt, schema, context or lookup, and read the advice.
- **App code** (`App/`) only compiles in CI. Keep changes there small and match the surrounding style.
- A finished build reaches the owner's phone through TestFlight about 15 minutes after the run goes green. Tell them the build number.

## Seeing what happens on the phone: Sentry

The app sends its log lines and errors to Sentry (`App/Shared/Log.swift`). Use them to find and confirm bugs before changing code.

- `Log.<category>.info / warning / error("...")`. Categories: app, oura, sync, health, backup, meditation, coach. `error` also opens a Sentry issue.
- **Never log health values, tokens, notes, or anything the user wrote**, including coach or chat questions, Claude's answers and the coach context. Status codes, counts, durations, endpoint names and error descriptions are fine.
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
