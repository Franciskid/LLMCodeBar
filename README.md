# LLMCodeBar

A tiny macOS menu bar app that shows how much of your **Claude** and **Codex** usage you've burned through — your 5‑hour session and weekly limits — without opening either app.

![LLMCodeBar dropdown showing Claude and Codex usage](assets/screenshot.png)

## Why

If you live in Claude (Claude Code) or Codex, you keep hitting invisible walls: the **5‑hour session** limit and the **weekly** cap. You never really know where you stand until you get cut off mid‑thought. LLMCodeBar puts that number in your menu bar, color‑coded, so you can glance at it and stop guessing.

## What it does

- Sits in your menu bar and shows the usage % of the account you choose.
- Click it for a dropdown per account: a **Session (5h)** bar and a **Weekly** bar, when each resets, and a small **7‑day trend line** that fades green → yellow → red as you approach the limit.
- Handles **multiple accounts** for both Claude and Codex, each launched in its own isolated window so you can juggle several logins.
- Optional **auto‑start 5h session**: when your session window is idle, it fires a tiny throwaway message on the cheapest model so the clock starts counting — handy if you want your window ticking on a predictable schedule.

## How it works / where the data comes from

Everything is local and read‑only against **your own** accounts. No server, no telemetry, nothing leaves your machine except the calls to Anthropic/OpenAI you'd be making anyway.

- It finds your signed‑in Claude/Codex desktop profiles in `~/Library/Application Support` and reads the account email/plan from the local app data.
- For live usage it reuses **your existing session**:
  - **Claude** — reads the session cookies (from the running Claude window's debug port, or the encrypted cookie store) and calls the same `claude.ai` usage endpoint the web app uses.
  - **Codex** — uses the OAuth token the Codex CLI already stored (`auth.json`) and calls the ChatGPT backend usage endpoint.
- The only things it saves are a small config and a 7‑day rolling history of usage numbers (for the sparklines), in Application Support.

Heads up: these are the apps' **unofficial** internal endpoints, so they can change. Subscription tier is inferred from local billing signals, so it's a best guess (a paid Claude account shows as "Pro").

## The keychain prompt (and how to stop it)

When the Claude app isn't running, LLMCodeBar decrypts Claude's cookie store to read usage, and macOS guards that key behind a keychain prompt. To make it stop asking every launch:

1. When the keychain dialog appears, click **Always Allow** (not just *Allow*). LLMCodeBar then caches the key in its *own* keychain item, so it won't ask again.
2. Prefer it never touch the keychain? Open **Settings → uncheck "Auto‑approve cookie access."** Usage then only refreshes while the Claude app is open (it reads cookies from the live window — no prompt).

Rebuilding from source changes the app's signature, so macOS may ask once more after that — normal for an unsigned app.

## Install

Download **`LLMCodeBar.dmg`** from the [latest release](https://github.com/Franciskid/LLMCodeBar/releases/latest), open it, and drag **LLMCodeBar** into Applications.

Since it isn't signed with a paid Apple Developer ID, Gatekeeper will grumble the first time ("cannot be opened because Apple cannot check it…"). One‑time fix — pick either:

- **Right‑click the app → Open → Open**, or
- run `xattr -dr com.apple.quarantine "/Applications/LLMCodeBar.app"`

Then it just lives in your menu bar. Flip on **Launch at login** in Settings to keep it there.

**Requirements:** macOS 13 (Ventura) or later · universal (Apple Silicon + Intel) · the Claude and/or Codex desktop apps installed and signed in.

## Build from source

Plain Swift + AppKit, compiled with `swiftc` — no Xcode project, no dependencies.

```sh
git clone https://github.com/Franciskid/LLMCodeBar.git
cd LLMCodeBar
./scripts/install.sh   # build → /Applications → launch
# ./scripts/build.sh   # just build to dist/
# ./scripts/dmg.sh     # build the .dmg installer
```

Source is split by feature under `src/` (models, cookie readers, usage refresher, menu views, settings, session auto‑start, …).

## Settings

- **Refresh every** — 30 s to 30 min.
- **Show this account's 5h % in the menu bar** — which account the menu‑bar number tracks (one at a time).
- **Show 7‑day trend sparklines**.
- **Auto‑approve cookie access** — the keychain behavior above.
- **Auto‑start 5h session** (per account) — the throwaway‑message trick. Claude works; Codex is experimental.

## Honest caveats

- Unofficial endpoints — they may break when the providers change things.
- Unsigned — you do the Gatekeeper dance once.
- Subscription tier is a local guess.
- Auto‑start sends a real (tiny) message to your account. That's the whole point, but it does spend a sliver of quota.

## License

MIT — do what you like.
