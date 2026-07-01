# LLMCodeBar

Menu bar app to watch your Claude and Codex usage, run several accounts of the same provider, and auto start your 5 hour session.

![LLMCodeBar menu with two accounts](assets/screenshot.png)

## What it does

- Shows the 5 hour session and weekly usage for each account, right in the menu bar.
- Handles multiple accounts, including several of the same provider, each in its own isolated login.
- Click an account in the dropdown to launch Claude or Codex signed into that account.
- Auto starts the 5 hour session (Claude and Codex): when an account is idle it sends a tiny message on the cheapest model to start the clock, so your window runs on a schedule. Toggle it per account.
- Per account: a Session (5h) bar, a Weekly bar, the reset times, and a 7 day trend line that goes green to red as you near the limit.
- Pick which account's % shows in the menu bar.
- Refresh from every 30 seconds to every 30 minutes.
- Launch at login.
- Add accounts from Settings, it opens a login window and picks them up automatically.

![LLMCodeBar settings](assets/settings.png)

## How it gets the data

Local and read only, on your own accounts. Nothing leaves your machine except the usual requests to Anthropic and OpenAI.

- Reads your signed in Claude and Codex profiles in `~/Library/Application Support` for the account and plan.
- Claude: your session cookies plus the claude.ai usage endpoint. Codex: the Codex CLI token in `auth.json` plus the ChatGPT usage endpoint.
- Saves a small config file and a 7 day usage history for the sparklines.

These are the apps' internal endpoints, not official ones, so they can break if the providers change them.

## Keychain prompt

When Claude isn't running, the app unlocks Claude's cookie key and macOS asks for your password. Click **Always Allow** once and it caches the key, so it stops asking. Or uncheck **Auto approve cookie access** in Settings and it only reads usage while Claude is open.

## Install

Get **LLMCodeBar.dmg** from the [latest release](https://github.com/Franciskid/LLMCodeBar/releases/latest), open it, drag the app to Applications.

It's unsigned, so the first launch macOS blocks it. Right click the app and pick Open, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/LLMCodeBar.app"
```

macOS 13 or newer, universal (Apple Silicon and Intel). You also need the Claude and/or Codex desktop apps installed and signed in.

## Build

```sh
git clone https://github.com/Franciskid/LLMCodeBar.git
cd LLMCodeBar
./scripts/install.sh   # build, install, launch
```

Plain Swift and AppKit, no Xcode project, no deps.

## License

MIT.
