# MeetNote

A small macOS menu bar app. Click once to record an online meeting (Zoom, FaceTime, Meet, anything that plays through your Mac), click again to stop. You get a markdown file with a timestamped transcript and speaker labels, plus an optional AI summary. The audio is deleted as soon as the transcript is written.

- **Local transcription.** Speech to text runs on your Mac ([FluidAudio](https://github.com/FluidInference/FluidAudio), Parakeet v3, English, French and 23 other languages). No cloud, no account.
- **Speakers.** Your microphone is "Me". The other side is "Them", split into "Speaker 1/2/3" when several voices are detected.
- **Summary (optional).** The transcript text, never the audio, is sent to a server you choose. Or turn summaries off.

```
~/Documents/MeetNote/2026-11/2026-11-05/2026-11-05 7.23 PM.md
```

## Requirements

macOS 14.4 or newer, Apple Silicon recommended, Xcode command line tools (`xcode-select --install`).

## Install

```bash
git clone <this repo> && cd MeetNote
./build.sh
cp -R build/MeetNote.app /Applications/
open /Applications/MeetNote.app
```

`build.sh` signs with your first "Apple Development" certificate if you have one (this keeps the permissions you grant between rebuilds). Without one it uses an ad-hoc signature, and macOS may ask for permissions again after each rebuild. The first time you open a build that is not notarized, right-click the app and choose Open.

The first recording downloads the speech models once (about 1 to 2 GB, kept in `~/Library/Application Support/FluidAudio`).

## Use

| Action | Result |
| --- | --- |
| Left click the icon | Start or stop recording |
| Right click the icon | Menu: summary steps, re-summarize, settings, open folder, quit |

While a summary runs, the icon shows one dot per step (gray waiting, blue working, green done, orange waiting for something, red failed). Right-click to see each step in words.

Permissions asked on first use: **Microphone** (your voice) and **System Audio Recording** (the other side).

**Tip:** use headphones. With speakers, your microphone also hears the other side. MeetNote filters most of that echo, but headphones remove it completely.

## Summary servers

Open **Settings** from the right-click menu.

| Choice | For |
| --- | --- |
| No summary | Transcript only |
| AI server | Any server with an OpenAI-style `/v1/chat/completions` endpoint: Ollama (`http://localhost:11434`), LM Studio (`http://localhost:1234`), llama.cpp, vLLM, OpenAI, OpenRouter. Enter address, model name, optional API key. |
| Wake-on-demand gateway | Advanced. A gateway that wakes a PC and reports progress as `> text` lines. Shows extra steps. |

Use **Test connection** to check the address, key and model name.

### Privacy and security

- Audio never leaves your Mac and is deleted after the transcript is written.
- Only the transcript text goes to the summary server. Settings shows whether that is your own network or the internet.
- Plain `http://` is accepted only for your own network (localhost, `192.168.x.x`, `10.x.x.x`, Tailscale `100.x.x.x`, `.local`). Anything else must use `https://`.
- The API key is stored in the macOS Keychain, not in a file.
- If you expose a model server beyond your own network, put it behind HTTPS and require an API key. Never open a model port to the internet without one.

## Troubleshooting

- **"No sound from the other side yet"**: allow MeetNote in System Settings > Privacy & Security > Screen & System Audio Recording, then record again.
- **Summary step fails**: right-click the icon. Each step shows what blocked it. "Re-summarize last transcript" tries again after you fix it.
- **Transcript says "Summary pending…" forever**: the app was closed during the summary. Right-click, "Re-summarize last transcript".

## How it works

Core Audio process tap for system audio, `AVAudioEngine` for the microphone, FluidAudio for transcription and speaker separation, a streaming chat request for the summary. The summary is written between `<!-- summary:start -->` and `<!-- summary:end -->` in the same file as the transcript. Sources are in `Sources/`: `MeetNote` (app), `SummaryKit` (summary engine), `SummaryCheck` (command line test tool).

## License

MIT

## Credits

MeetNote is glue around other people's work. Thank you to:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0): runs the speech and speaker models on the Mac.
- [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY 4.0): speech to text.
- [pyannote Community-1](https://huggingface.co/pyannote) speaker separation, as Core ML conversions by [FluidInference](https://huggingface.co/FluidInference/speaker-diarization-coreml) (CC-BY 4.0).

The models are downloaded on first use; they are not part of this repository.
