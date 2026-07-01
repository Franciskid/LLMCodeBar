# LLM Usage Bar

Native macOS menu bar app for launching isolated Claude/Codex desktop profiles and tracking local subscription-window usage estimates.

## What works now

- Menu bar dropdown with Claude and Codex profiles.
- Settings window for adding/removing/editing profiles.
- `Add Account...` opens Claude or Codex in a new isolated profile folder so you can sign in there.
- Pending account rows are kept and refreshed until the app detects login data.
- Connected-account inference from existing support folders such as:
  - `~/Library/Application Support/Claude`
  - `~/Library/Application Support/Claude-*`
  - `~/Library/Application Support/Codex`
  - `~/Library/Application Support/com.openai.codex`
  - `~/Library/Application Support/LLM Usage Bar/Profiles/...`
- Real account labels are used when the local app profile exposes a name or email.
- Profiles without connected-account evidence are ignored.
- Isolated launches using the app executable plus `--user-data-dir=<profile folder>`.
- Autostart by writing a user LaunchAgent.

## Important quota note

Claude and Codex subscription-window quotas are provider-side and dynamic. This app does not invent local quota percentages. It scans the real local app cache for billing, plan, and quota/rate-limit metadata. If the exact remaining 5-hour or weekly quota is not cached by the provider app, the row says that instead of guessing.

Codex may store the signed-in username hashed/encrypted in Chromium `Secure Preferences`. In that case the app can detect that a Codex account is signed in, but cannot always display the real email/name without a provider-side query.

## Build

```sh
./scripts/build.sh
open "dist/LLM Usage Bar.app"
```

Verify inference without opening the UI:

```sh
"dist/LLM Usage Bar.app/Contents/MacOS/LLMUsageBar" --dump-inferred-json
```

To install into `/Applications`:

```sh
./scripts/install.sh
```

## Data

Runtime config lives in:

```txt
~/Library/Application Support/LLM Usage Bar/config.json
~/Library/Application Support/LLM Usage Bar/usage_events.json
```

Autostart uses:

```txt
~/Library/LaunchAgents/fr.fraserv.llmusagebar.plist
```

## Next useful steps

- Verify whether Claude/Codex accept `--user-data-dir` consistently across updates.
- Add provider-specific quota adapters once the quota source is identified.
- Add a signed/notarized release build if this will leave your machine.
