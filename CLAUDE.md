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
  `gh pr`/`gh issue` (GraphQL) don't work through the cloud proxy; use `gh api` (REST).
- **Core logic is plain Swift** in `Packages/EightyTwentyCore` (no UIKit/HealthKit), with tests. Run them before pushing. Put new logic there, with tests, whenever it doesn't need Apple frameworks. If `swift` is installed, `cd Packages/EightyTwentyCore && swift test`. If not (swift.org downloads are blocked, Docker Hub works), use the `swift:6.1` image; the CA mount lets the container through the session's TLS proxy:
  ```sh
  (sudo dockerd > /tmp/dockerd.log 2>&1 &); sleep 5; docker pull swift:6.1
  cd Packages/EightyTwentyCore && docker run --rm --network host -e CLAUDE_COACH_API_KEY \
    -v /root/.ccr/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro \
    -v swiftbuild:/tmp/build -v "$PWD":/pkg -w /pkg swift:6.1 swift test --scratch-path /tmp/build
  ```
- **Coach live test**: `CoachLiveTests` calls the real Claude API with the owner's 1 PM scenario and prints both answers (`--filter CoachLiveTests`). It runs only when `CLAUDE_COACH_API_KEY` is set (cloud sessions; never `ANTHROPIC_API_KEY`, which Claude Code itself may read), and is skipped in CI. Never print or write the key. Run it after any change to the coach's system prompt, schema or context, and read the advice.
- **App code** (`App/`) only compiles in CI. Keep changes there small and match the surrounding style.
- A finished build reaches the owner's phone through TestFlight about 15 minutes after the run goes green. Tell them the build number.

## Seeing what happens on the phone: Sentry

The app sends its log lines and errors to Sentry (`App/Shared/Log.swift`). Use them to find and confirm bugs before changing code.

- `Log.<category>.info / warning / error("...")`. Categories: app, oura, sync, health, backup, coach. `error` also opens a Sentry issue.
- **Never log health values, tokens, notes, or anything the user wrote**, including coach questions, Claude's answers and the coach context. Status codes, counts, durations, endpoint names and error descriptions are fine.
- Environments: `debug` (Xcode builds), `testflight`, `production`.

Querying (org and project come from the environment; the auth token is either `$SENTRY_AUTH_TOKEN` or injected for sentry.io by the environment's network secret):

```sh
S=https://sentry.io/api/0
AUTH=(); [ -n "$SENTRY_AUTH_TOKEN" ] && AUTH=(-H "Authorization: Bearer $SENTRY_AUTH_TOKEN")

# Unresolved issues, last 7 days
curl -s "${AUTH[@]}" "$S/projects/$SENTRY_ORG/$SENTRY_PROJECT/issues/?query=is:unresolved&statsPeriod=7d" \
  | jq -r '.[] | "\(.id)  \(.count)x  last \(.lastSeen)  \(.title)"'

# Latest event of an issue (message, tags, device, release)
curl -s "${AUTH[@]}" "$S/organizations/$SENTRY_ORG/issues/<ISSUE_ID>/events/latest/" \
  | jq '{message: .message, tags: .tags, release: .release}'

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
