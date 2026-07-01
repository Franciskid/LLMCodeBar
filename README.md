# LLMCodeBar

A tiny macOS menu bar app for people juggling several Claude and Codex accounts, with one trick the other usage trackers don't have: it can automatically start your 5 hour session so the clock is always running.

![LLMCodeBar dropdown showing two accounts](assets/screenshot.png)

## What makes it different

Plenty of menu bar apps already show your Claude or Codex usage, and they do it fine. LLMCodeBar exists for two things those don't do:

**1. Multiple accounts of the same provider.** Two Claude accounts and two Codex accounts? A personal one and a work one? LLMCodeBar tracks all of them at once, each in its own isolated login window so they never step on each other. Every account gets its own row in the dropdown.

**2. Auto starting the 5 hour session.** The 5 hour window only starts counting once you send your first message, so if you're not actively using it the clock just sits there. Turn this on for an account and, whenever its session is idle, LLMCodeBar quietly sends one tiny throwaway message on the cheapest model to kick the clock off. Now your window runs (and resets) on a schedule instead of only when you remember to poke it. Works on both Claude and Codex.

That's the whole reason the app exists. Everything below is the usual usage tracking, done nicely.

## The rest

- Sits in your menu bar and shows the usage % of whichever account you pick.
- Click it for a dropdown per account: a Session (5h) bar, a Weekly bar, when each one resets, and a little 7 day trend line that fades from green to red as you get closer to the limit.
- Refreshes as often as every 30 seconds.
- Launches at login if you want, so it's just always there.

## How it works (and where the data comes from)

Everything is local and read only against your own accounts. No server, no tracking, nothing leaves your machine except the calls to Anthropic and OpenAI you'd be making anyway.

- It finds your signed in Claude and Codex desktop profiles in `~/Library/Application Support` and reads the account email and plan straight from the local app data.
- For the live numbers it reuses the session you already have:
  - Claude: reads your session cookies (from the running Claude window, or the encrypted cookie store) and calls the same claude.ai usage endpoint the web app uses.
  - Codex: uses the OAuth token the Codex CLI already saved (`auth.json`) and calls the ChatGPT backend usage endpoint.
- The only things it keeps are a small config file and a 7 day rolling history of usage numbers, which is what feeds the sparklines.

Fair warning: these are the apps' own internal endpoints, not official public ones, so they can change on you. The auto start and the multi account launching lean on the same internal machinery.

## Making the keychain prompt go away

When the Claude app isn't running, LLMCodeBar has to decrypt Claude's cookie store to read usage, and macOS guards that key with a password prompt. Two ways to shut it up:

1. When the keychain box pops up, hit **Always Allow** (not just Allow). After that LLMCodeBar stashes the key in its own keychain item, so it stops asking.
2. Or keep it away from the keychain entirely: open Settings and uncheck **Auto approve cookie access**. Then it only refreshes while the Claude app is open, reading cookies from the live window, no prompt.

(Rebuilding from source changes the app signature, so macOS might ask one more time after that. Normal for an unsigned app.)

## Install

Grab **LLMCodeBar.dmg** from the [latest release](https://github.com/Franciskid/LLMCodeBar/releases/latest), open it, drag LLMCodeBar into Applications.

I haven't paid Apple for a Developer ID, so Gatekeeper will whine the first time ("cannot be opened because Apple cannot check it"). One time fix, pick one:

- right click the app, Open, then Open again, or
- run `xattr -dr com.apple.quarantine "/Applications/LLMCodeBar.app"`

Then it just sits in your menu bar. Turn on **Launch at login** in Settings to keep it there.

**Needs:** macOS 13 (Ventura) or newer, universal so it runs on both Apple Silicon and Intel, and the Claude and/or Codex desktop apps installed and signed in.

## Build it yourself

Plain Swift and AppKit, built with `swiftc`. No Xcode project, no dependencies.

```sh
git clone https://github.com/Franciskid/LLMCodeBar.git
cd LLMCodeBar
./scripts/install.sh   # build, drop in /Applications, launch
# ./scripts/build.sh   # just build to dist/
# ./scripts/dmg.sh     # build the .dmg installer
```

Source is split by feature under `src/`.

## Settings

- **Refresh every**: 30s up to 30min.
- **Show this account's 5h % in the menu bar**: which account the menu bar number follows, one at a time.
- **Show 7 day trend sparklines**.
- **Auto approve cookie access**: the keychain thing above.
- **Auto start 5h session** (per account): the throwaway message trick, for Claude and Codex.

## Honest caveats

- These are unofficial endpoints, they might break when the providers change stuff.
- The app is unsigned, so you do the Gatekeeper dance once.
- Subscription tier is a local guess (paid Claude shows as Pro).
- Auto start sends a real (tiny) message to your account. That's the whole point, but yeah, it spends a sliver of quota.

## License

MIT, do whatever you want.
