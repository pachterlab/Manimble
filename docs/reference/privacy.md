# Privacy and network use

Manimble is an app on your Mac, not an online service. It has no accounts, analytics, telemetry or crash reporting,
and it doesn't check for updates. Your decks stay on your Mac: Manimble never uploads a slide, a deck or its code
unless you ask it to send something.

Manimble connects to the internet only for the features below, and only when you use them. Each connection reaches
the server named, which sees your IP address, as any web request does.

## When Manimble connects

| What you do | Where it connects | What is sent |
|---|---|---|
| Install dependencies on first launch, or with *Manimble ▸ Install Dependencies…* | GitHub (`github.com`, `api.github.com`) for the Python runtime and TinyTeX; a CTAN mirror for LaTeX packages | Download requests only. Each download is checked against its SHA-256 before it is used. |
| Browse or search [BioCartoon icons](../guide/pictures.md#biocartoon-icons) | `assets.biocartoon.com` | Requests for the icon catalog and the pictures you view or insert. Searches run on your Mac, so what you type is not sent. |
| Star a BioCartoon icon, or show star counts | `api.biocartoon.com` | The icon's ID and a random ID made for this Mac, which tells stars apart without saying who gave them. |
| Submit a picture to BioCartoon | `api.biocartoon.com` | The picture, and the details you enter: title, description, category, tags, author, license, whether generative AI was used, and your email address if you give one. The email is never published. |
| Submit a presentation to the [Examples page](../examples.md), on the website or with `manimbler --submit` | `api.manimble.com` | The `.manimble` package and the details you enter: title, authors, institution, date, keywords and description. They are published only if the example is approved; a rejected package is deleted. A salted hash of your IP address is kept to limit uploads per day. |
| Use an [online voice](../presenting/scripted.md#online-voices) for a scripted presentation | ElevenLabs (`api.elevenlabs.io`) or OpenAI (`api.openai.com`), with your own API key | The script text being spoken and the voice settings. The service's own privacy policy applies. The speech comes back and is cached on your Mac, so replaying doesn't send it again. |
| Paste a picture copied from a web page | The site the picture is on | A request for that picture. |
| Install an AI agent from the [terminal](../ai/terminal.md) | The agent's own installer (for example `claude.ai` for Claude Code) | Download requests only. |

System voices, Keynote import and export, PowerPoint and PDF export, and rendering all run on your Mac without a
network connection.

## AI agents

An AI coding agent you run in Manimble's terminal, such as Claude Code, Codex or Gemini CLI, is a separate program.
It sends what it reads, including your slides' code, to its own service, under your account with that service and
its privacy policy. Manimble doesn't send the agent anything itself.

## What Manimble keeps on your Mac

- **Your decks and projects**, where you save them. Manimble's working copies and render caches are in
  `~/Library/Application Support/Manimble`.
- **The Python runtime and TinyTeX**, in `~/Library/Application Support/Manimble/python` and `~/Library/TinyTeX`.
- **Settings** in Manimble's preferences, and **API keys** for online voices in your login keychain, never in a deck.
- **Speech from online voices**, cached in `~/Library/Caches/Manimble/voice`.
- **BioCartoon icons** you downloaded, and your stars, under `~/Library/Application Support/biocartoon`.

Deleting these folders, and the keychain items named `org.pachterlab.Manimble.voice`, removes everything Manimble
has stored.

## Questions

Ask in a [GitHub issue](https://github.com/pachterlab/Manimble/issues). To report a security problem privately, see
the [security policy](https://github.com/pachterlab/Manimble/blob/main/SECURITY.md).
