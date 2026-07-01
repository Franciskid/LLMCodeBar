# LLM Usage Bar

Native macOS menu bar app for launching isolated Claude/Codex desktop profiles and showing locally detectable account/subscription identity.

## What works now

- Menu bar dropdown with Claude and Codex profiles.
- Settings window for adding/removing/editing profiles.
- The Settings account list has a `+` button that opens Claude or Codex in a new isolated profile folder so you can sign in there.
- Pending account rows are kept and refreshed until the app detects login data.
- Connected-account inference from existing support folders such as:
  - `~/Library/Application Support/Claude`
  - `~/Library/Application Support/Claude-*`
  - `~/Library/Application Support/Codex`
  - `~/Library/Application Support/com.openai.codex`
  - `~/Library/Application Support/LLM Usage Bar/Profiles/...`
- Real account labels are used when the local app profile exposes a name or email.
- Profiles without connected-account evidence are ignored.
- Isolated launches through the macOS app bundle plus `--user-data-dir=<profile folder>`.
- Autostart by writing a user LaunchAgent.

## Subscription Note

Claude and Codex subscription tiers are provider-side account data. This app does not invent local subscription or quota values. It shows the subscription tier only when the local app profile exposes a real billing/plan signal, such as Claude's local `billing_type` cache.

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
- Add provider-specific quota adapters if Claude or Codex expose a reliable local or official quota source.
- Add a signed/notarized release build if this will leave your machine.
