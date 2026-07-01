# LLMCodeBar

Menu bar app to keep an eye on your Claude and Codex usage.

The main reason it exists: it handles multiple accounts of the same provider (like two Claude accounts), and it can automatically start your 5 hour session for you. Most usage bar apps don't do either.

![LLMCodeBar dropdown showing two accounts](assets/screenshot.png)

## What it does

- Shows your Claude and Codex usage in the menu bar: the 5 hour session limit and the weekly one.
- Handles as many accounts as you want, including several from the same provider. Each one opens in its own isolated window so they don't clash.
- Can auto start the 5 hour session. The window only starts counting once you send a message, so if an account is sitting idle the app sends a tiny message on the cheapest model to start the clock. Works for Claude and Codex, you turn it on per account.
- Click the icon for a dropdown: each account with a Session (5h) bar, a Weekly bar, the reset times, and a 7 day trend line that goes green to red as you get close to the limit.
- Refreshes anywhere from every 30 seconds to every 30 minutes, your call.
- Can launch at login.

## How it gets the data

It's all local and read only, on your own accounts. Nothing leaves your machine except the requests to Anthropic and OpenAI you'd be making anyway.

- It reads your signed in Claude and Codex profiles from `~/Library/Application Support` to get the account email and plan.
- For the live usage it uses the session you already have:
  - Claude: reads your session cookies (from the running Claude window or the encrypted cookie store) and hits the same claude.ai usage endpoint the web app uses.
  - Codex: uses the OAuth token the Codex CLI saved in `auth.json` and hits the ChatGPT backend usage endpoint.
- It saves a small config file and a 7 day history of usage numbers for the sparklines. That's it.

These are the apps' internal endpoints, not official ones, so they can break if the providers change them.

## The keychain password prompt

When the Claude app isn't running, LLMCodeBar decrypts Claude's cookie store to read usage, and macOS asks for your password to unlock the key. To stop it asking every time:

- Click **Always Allow** when the prompt shows up (not just Allow). The app caches the key after that so it won't ask again.
- Or open Settings and uncheck **Auto approve cookie access**. Then it never touches the keychain, and usage only updates while the Claude app is open.

Rebuilding from source changes the app signature, so macOS might ask once more after that.

## Install

Download **LLMCodeBar.dmg** from the [latest release](https://github.com/Franciskid/LLMCodeBar/releases/latest), open it, drag the app to Applications.

It's not signed with an Apple Developer ID, so the first time macOS will say it can't check it. Either right click the app and pick Open, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/LLMCodeBar.app"
```

Needs macOS 13 or newer. Universal build, runs on Apple Silicon and Intel. You also need the Claude and/or Codex desktop apps installed and signed in.

## Build it yourself

Plain Swift and AppKit, no Xcode project, no dependencies.

```sh
git clone https://github.com/Franciskid/LLMCodeBar.git
cd LLMCodeBar
./scripts/install.sh   # build, put it in /Applications, launch
# ./scripts/build.sh   # just build to dist/
# ./scripts/dmg.sh     # build the dmg
```

## Settings

- Refresh interval, 30s to 30min.
- Which account's 5h % shows in the menu bar.
- Show the sparklines or not.
- Auto approve cookie access (the keychain thing above).
- Auto start 5h session, per account.

## Caveats

- Unofficial endpoints, might break when the providers change things.
- Unsigned, so you deal with the Gatekeeper warning once.
- The plan (Pro and so on) is a guess from local data.
- Auto start sends a real message to your account. A small one, but it uses a bit of quota.

## License

MIT.
