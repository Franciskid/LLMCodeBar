# LLM Usage Bar

Native macOS menu bar app for launching isolated Claude/Codex desktop profiles and tracking local subscription-window usage estimates.

## What works now

- Menu bar dropdown with Claude and Codex profiles.
- Settings window for adding/removing/editing profiles.
- Profile inference from existing support folders such as:
  - `~/Library/Application Support/Claude`
  - `~/Library/Application Support/Claude-*`
  - `~/Library/Application Support/Codex`
  - `~/Library/Application Support/com.openai.codex`
- Isolated launches using the app executable plus `--user-data-dir=<profile folder>`.
- Local 5-hour and 7-day usage estimates.
- Autostart by writing a user LaunchAgent.

## Important quota note

Claude and Codex subscription-window quotas are provider-side, dynamic, and not currently exposed through a stable public desktop API. This app's first version records local launch/session markers and displays those against configurable 5-hour and weekly budgets. The code keeps quota collection isolated so a later adapter can scrape a dashboard or call a private/official endpoint if one becomes available.

## Build

```sh
./scripts/build.sh
open "dist/LLM Usage Bar.app"
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
