# Local setup runbook (for Claude Code on the owner's Mac)

You are Claude Code running on the owner's personal Mac (Xcode installed), started with `claude --chrome` from the root of this repo. Your job: get the app onto their iPhone today (Part A), then set up the GitHub Actions to TestFlight pipeline so future changes reach the phone without this Mac (Part B), then report (Part C).

The owner wants to do as little as possible. Do the work yourself, in the terminal and in their logged-in Chrome. Only hand things back for what truly needs a human: Apple 2FA codes, taps on the iPhone, and approving a download.

## Rules

- **Every step is check-first.** Some of this may already exist (the owner started on another computer). If it's done, say so and move on. Never create duplicates.
- **Secrets never go into git or chat.** `Config/Secrets.xcconfig` is gitignored; keep it that way. Don't echo secret values in your replies or in command output (pipe them, don't print them). The `.p8` key file gets deleted at the end of Part B.
- **Branch:** work on `claude/inspiring-goodall-huc7gh`. `git pull` before any push. Never push to `main`.
- **Ask before anything destructive on Apple's or Oura's side** (revoking keys or certificates, deleting identifiers or apps). Exception: regenerating the Oura client secret is fine if it can't be read, because nothing uses it yet.
- If a step fails twice the same way, stop and report it instead of looping.

## Fixed values

| Thing | Value |
|---|---|
| GitHub repo | `mrellcrane/eightytwentyhealth` |
| Bundle ID | `com.mrellcrane.eightytwenty` (from `BUNDLE_ID_PREFIX` in `Config/Base.xcconfig`) |
| iCloud container | `iCloud.com.mrellcrane.eightytwenty` |
| Oura client ID | `682e6545-f8eb-44eb-aea1-2693c4342c5f` |
| Oura redirect URI | `eightytwenty://oauth-callback` |
| Oura scopes the app requests | email, personal, daily, heartrate, workout, tag, session, spo2Daily, stress, heart_health |
| App Store Connect app name | `80/20 Health` (if taken: `EightyTwenty Health`) |
| SKU | `eightytwenty-health` |

## Part A: app on the phone

### A1. Preflight

```sh
xcodebuild -version
command -v xcodegen || brew install xcodegen
command -v gh || brew install gh
gh auth status
```

- If `gh auth status` says not logged in, ask the owner to type `! gh auth login` in this Claude Code session (it's interactive), then continue.
- Xcode must be signed in to the owner's Apple developer account (Xcode > Settings > Accounts). Check with `defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null | head` or just let the build in A4 tell you; if signing says no account, ask the owner to add it in Xcode.

### A2. Team ID

```sh
security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject 2>/dev/null \
  | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | sort -u
```

- One result: that's the team ID.
- Several: show them to the owner and ask which team (or cross-check developer.apple.com > Account > Membership details in Chrome).
- None: open Xcode once (Settings > Accounts > Manage Certificates > + Apple Development), or let A4's `-allowProvisioningUpdates` create one, then re-run.

### A3. Oura secret and `Config/Secrets.xcconfig`

1. In Chrome, open <https://cloud.ouraring.com/oauth/applications> and open the app whose client ID is `682e6545-...`.
   - Confirm the redirect URI `eightytwenty://oauth-callback` is listed, and that the **Stress** and **Heart Health** scopes are ticked. Fix and save if not.
   - Read the client secret off the page. If it's hidden and can't be revealed, regenerate it (nothing uses it yet).
2. Write the file without echoing the secret:

```sh
cat > Config/Secrets.xcconfig <<EOF
DEVELOPMENT_TEAM = <team id from A2>
BUNDLE_ID_PREFIX = com.mrellcrane
OURA_CLIENT_ID = 682e6545-f8eb-44eb-aea1-2693c4342c5f
OURA_CLIENT_SECRET = <secret>
EOF
git check-ignore -q Config/Secrets.xcconfig && echo "ignored, good"
```

If the secret contains `//`, write those characters as `/$()/` (xcconfig treats `//` as a comment).

3. Optional sanity check of the credentials (a fake code should come back as `invalid_grant`, which means the ID and secret are accepted; `invalid_client` means the secret is wrong):

```sh
curl -s https://api.ouraring.com/oauth/token -d grant_type=authorization_code -d code=check \
  --data-urlencode redirect_uri=eightytwenty://oauth-callback \
  --data-urlencode client_id=682e6545-f8eb-44eb-aea1-2693c4342c5f \
  --data-urlencode client_secret="$(sed -n 's/^OURA_CLIENT_SECRET = //p' Config/Secrets.xcconfig)" \
  | grep -o '"error":"[a-z_]*"'
```

### A4. Build and install

```sh
xcodegen generate
xcrun devicectl list devices
```

- If no phone shows up: ask the owner to plug it in (or have it on the same Wi-Fi, already paired), unlock it, tap **Trust This Computer**, and turn on **Settings > Privacy & Security > Developer Mode** (the phone restarts).
- Get the phone's hardware UDID (xcodebuild wants the UDID, not the CoreDevice identifier): `xcrun devicectl list devices --json-output /tmp/devices.json` and read `result.devices[].hardwareProperties.udid`, or use `xcodebuild -showdestinations -scheme EightyTwenty -project EightyTwenty.xcodeproj`.

```sh
xcodebuild build \
  -project EightyTwenty.xcodeproj -scheme EightyTwenty -configuration Debug \
  -destination "id=<UDID>" -derivedDataPath build \
  -allowProvisioningUpdates
xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/EightyTwenty.app
xcrun devicectl device process launch --device <UDID> com.mrellcrane.eightytwenty
```

Automatic signing with `-allowProvisioningUpdates` should register the bundle ID, the device, HealthKit, Push and the iCloud container. If it complains about the iCloud container:

- In Chrome, developer.apple.com > Certificates, Identifiers & Profiles > Identifiers: create the iCloud container `iCloud.com.mrellcrane.eightytwenty` if missing, then open the App ID `com.mrellcrane.eightytwenty`, make sure HealthKit, iCloud (with CloudKit, container assigned) and Push Notifications are on, save, and rebuild.

If the build fails on Swift code (it compiles in CI, so this would be SDK drift): fix it, keep the change minimal, commit to the branch with a clear message, push.

### A5. Hand-off to the owner (they tap, you wait)

Tell the owner to do these on the phone, then confirm:

1. Open **80/20**. Allow notifications (wind-down reminder and morning brief).
2. **Settings > Connect Oura**, sign in, approve.
3. **Settings > Allow Apple Health access**, turn everything on.
4. The Today tab should show both bars within a minute.

## Part B: TestFlight pipeline

Goal: every push to the branch builds in GitHub Actions and lands in TestFlight. The workflow is `.github/workflows/ios.yml`; it switches from compile-check to archive-and-upload as soon as these six repo secrets exist: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID`, `OURA_CLIENT_ID`, `OURA_CLIENT_SECRET`.

### B1. App Store Connect app record (Chrome)

<https://appstoreconnect.apple.com/apps>: if an app with bundle ID `com.mrellcrane.eightytwenty` exists, skip. Otherwise **+ > New App**: iOS, name from the table above, English (U.S.), bundle ID `com.mrellcrane.eightytwenty` (exists after A4), SKU `eightytwenty-health`, Full Access.

### B2. App Store Connect API key (Chrome)

<https://appstoreconnect.apple.com/access/integrations/api> > **Team Keys**.

- If a key named `GitHub CI` already exists, you can't re-download its `.p8` (Apple allows one download). Ask the owner whether to revoke it and make a new one, or whether they still have the file.
- Otherwise **Generate API Key**: name `GitHub CI`, access **Admin** (needed for cloud-managed signing). Download the `.p8` (lands in `~/Downloads/AuthKey_<KEYID>.p8`; the owner may need to approve the download). Read the **Key ID** from the table and the **Issuer ID** from the top of the page.

### B3. GitHub secrets (terminal)

Pipe values in so they never appear in output:

```sh
R=mrellcrane/eightytwentyhealth
printf %s "<KEY ID>"    | gh secret set ASC_KEY_ID -R $R
printf %s "<ISSUER ID>" | gh secret set ASC_ISSUER_ID -R $R
gh secret set ASC_KEY_P8 -R $R < ~/Downloads/AuthKey_<KEYID>.p8
printf %s "<TEAM ID>"   | gh secret set APPLE_TEAM_ID -R $R
sed -n 's/^OURA_CLIENT_ID = //p'     Config/Secrets.xcconfig | tr -d '\n' | gh secret set OURA_CLIENT_ID -R $R
sed -n 's/^OURA_CLIENT_SECRET = //p' Config/Secrets.xcconfig | tr -d '\n' | gh secret set OURA_CLIENT_SECRET -R $R
gh secret list -R $R
```

Only after `gh secret list` shows all six: `rm ~/Downloads/AuthKey_*.p8` (and empty it from the Trash if it went there). It's an admin key to the developer account.

### B4. TestFlight group (Chrome)

App Store Connect > the app > **TestFlight** > Internal Testing > **+**: group `Me`, add the owner's Apple ID as a tester, turn on automatic distribution. Skip if it already exists.

### B5. First build

```sh
R=mrellcrane/eightytwentyhealth
gh workflow run ios.yml -R $R --ref claude/inspiring-goodall-huc7gh
sleep 10; RUN=$(gh run list -R $R --workflow ios.yml -L 1 --json databaseId -q '.[0].databaseId')
gh run watch $RUN -R $R --exit-status || gh run view $RUN -R $R --log-failed | tail -80
```

The log line "App Store Connect secrets found: archiving for TestFlight." confirms the mode. Likely failure fixes (edit `.github/workflows/ios.yml`, commit, push, re-run; at most 3 rounds, then report):

- **No devices / no development profile:** Part A registers the phone; make sure A4 succeeded first.
- **Signing certificate errors in the archive step:** the API key needs Admin. If Xcode refuses to create a development certificate, try archiving with `CODE_SIGN_IDENTITY="Apple Distribution"` while keeping automatic signing, so the archive uses the cloud-managed distribution certificate.
- **"No app record" / bundle ID mismatch on upload:** B1 isn't done, or the name/bundle differ.
- **Upload rejected for a missing purpose string:** add the string to `App/Info.plist`.

After a green run, the build shows in TestFlight after Apple's processing (usually 5 to 15 minutes). Ask the owner to install the TestFlight app and accept the build. TestFlight and Xcode builds share the same iCloud data (the entitlements pin CloudKit to the Development environment), so switching between them loses nothing.

## Part C: report

Finish with a short checklist for the owner:

- [ ] App installed and launched on the phone (A4)
- [ ] Oura connected, Health allowed, bars showing (owner confirms, A5)
- [ ] App record, API key, six secrets, `.p8` deleted (B1 to B3)
- [ ] TestFlight group (B4)
- [ ] First TestFlight build: run URL and build number (B5)
- Anything skipped, blocked, or changed in the repo (with commit hashes)
