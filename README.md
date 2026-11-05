# FalaMac

A lightweight macOS dictation app: speak, let AI clean up your words, and paste the result into the active text field.

**Early testing version.** Built for personal use and now shared for others to try. Auto-paste can be inconsistent in some apps; the floating bar always offers **Copy text** after processing.

## Download

[Download the test build](https://github.com/bicalhoart/falamac/releases/tag/v0.3.0) → choose **FalaMac-0.3.0-arm64.zip** under Assets.

- The prebuilt app is for **Apple Silicon Macs (M1 or later), macOS 13 or newer**.
- Unzip it and move **FalaMac.app** to **Applications** before opening it.
- This personal build is ad-hoc signed, **not Developer ID signed or notarized by Apple**. macOS may block the download from opening. Review [Apple's guidance on opening downloaded apps](https://support.apple.com/en-us/102445) before deciding whether to run it. You can also build from the source below.
- No subscription or account with FalaMac is required. You need your own API accounts and keys; any API charges belong to those providers.

## Set up

1. Get your own [Groq API key](https://console.groq.com/keys) for speech transcription. This is **Groq**, not xAI's Grok.
2. Get your own [OpenRouter API key](https://openrouter.ai/settings/keys) for text cleanup. Set a spending limit on that key and check your account balance.
3. Open FalaMac → **Settings → Edit API keys…**, enter both keys, and click **Save keys**. Keys are stored in your Mac's Keychain. Do not paste keys into GitHub issues or screenshots.
4. Allow **Microphone** access when recording, and use **Allow Accessibility** so FalaMac can detect the active field and paste into other apps.
5. Choose a shortcut and click **Save changes**. **Control + Option + Space** works as a toggle. Fn can either toggle or work as push-to-talk.
6. If using Fn, open **Settings → More options… → Keyboard settings** and set **Press 🌐 key to → Do Nothing** in macOS. Use **Control + Space** or the input menu to switch keyboard languages.

After an update, macOS may require Accessibility approval again. **Unlock saved keys** requests access to existing Keychain entries; enter your Mac login password only in the system prompt. Denying access does not delete the keys.

## Use

- Press your shortcut to record, then press it again to finish (or release Fn in hold mode).
- You can move to a different field or app while speaking. FalaMac uses the field selected when the finished text is delivered.
- The floating bar shows recording and processing. **Cancel · Esc** cancels an active recording before upload.
- After processing, use **Copy text** if auto-paste does not appear. Press **⌘V** in your chosen field. **Close** dismisses the bar.
- Text cleanup preserves your spoken language, favors bullet points for multiple ideas, and keeps the final version of spoken self-corrections. Model output still needs review.
- If cleanup fails, the original transcript is marked **Not cleaned up**, with **Retry cleanup** available for the latest result in the session. Retrying sends only that text to OpenRouter.
- Closing the main window keeps FalaMac running in the menu bar. **Quit FalaMac** stops it. Turn off **Launch at login** in Settings if you do not want it to start with your Mac.
- **Pause music while recording** sends a pause command to the current macOS media session. Resume playback manually in your player.

## Screens

- **History:** search and copy recent dictations.
- **Settings:** shortcuts, retention, startup, API connections, and paste testing. **Help** contains usage instructions.
- **Usage:** a local monthly estimate and usage reported by your OpenRouter key. Key allowance is not account credit balance. Groq billing is checked on its own dashboard.

**The local monthly limit is an estimate, not a provider billing guarantee.** Set spending limits with your providers too. OpenRouter usage covers all apps sharing that key and uses UTC day/month boundaries. Failed requests may retain a conservative local cost reservation.

## Privacy and storage

FalaMac is a local Mac app with **cloud AI processing**:

- Audio goes to **Groq** (`whisper-large-v3-turbo`). The transcript and editing instructions go to **OpenRouter** and its selected provider (`google/gemini-2.5-flash-lite`). Provider privacy and retention policies apply.
- It does not upload your history, existing clipboard, screen contents, or app names. It requests OpenRouter providers with data collection disabled; this does not make processing offline.
- API keys stay in **macOS Keychain**. No keys, personal transcripts, usage records, or audio are bundled with the app or source.
- Audio is capped at **5 minutes** per recording (about 1.2 MB), then deleted locally after success, failure, or cancellation. Leftover audio from interrupted sessions is cleaned up on the next launch.
- History is plain text in `~/Library/Application Support/FalaMac/`, with owner-only permissions. Retention is off, 1, 7, or 30 days, with a 10 MB / 3,000-entry cap. Cleanup runs at launch and hourly while open. Mac backups may retain older copies.
- Auto-paste temporarily uses the clipboard, restoring its prior contents after three seconds unless something else was copied. Explicit **Copy text** leaves the result on the clipboard. Clipboard managers may see it.
- No local AI models, server, or app analytics are installed.

## Current limitations

- Tested on one Apple Silicon Mac. Other macOS versions, keyboard layouts, players, and editors still need testing.
- Auto-paste is best effort. Dispatching a paste shortcut does not confirm that the destination accepted it. Protected fields are excluded.
- Music pause uses a private macOS MediaRemote command and may stop working with a system/player update. Failure does not prevent dictation.
- Transcription and cleanup can make mistakes. Review output before using it.

## Build from source

Requires Apple's Command Line Tools with Swift 6 or newer. Full Xcode is not required. The build uses the host Mac's architecture; an Intel build has not been validated.

```sh
git clone https://github.com/bicalhoart/falamac.git
cd falamac
bash scripts/build.sh
```

Copy `dist/FalaMac.app` to Applications before granting permissions. Builds remove debug symbols and remap source paths so shared binaries do not expose the builder's home directory.

```sh
bash scripts/test.sh
```

Tests cover retention, storage, request structure, incomplete AI responses, field metadata, and usage accounting. Recording, permissions, model quality, and cross-app paste require testing on a real Mac.

After keeping a copy of the app, `.build/` and `dist/` can be removed to reclaim compilation space. Only remove these directories inside this repository.

[Documentação detalhada em português](README.pt-BR.md)
