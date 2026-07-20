# Getting Started with OSA

A beginner friendly guide to installing OSA, connecting a model, and doing your first real work. No prior setup knowledge needed. If you can paste one line into a terminal, you can run OSA.

OSA runs locally on your own machine and works with any model. This guide walks you through the fastest path, then shows the alternatives.

---

## 1. Install (one command)

You do not need Elixir, Erlang, Rust, or any toolchain. The installer downloads a prebuilt release that bundles everything.

**macOS / Linux**, paste into a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.sh | sh
osa
```

**Windows**, paste into PowerShell:

```powershell
irm https://raw.githubusercontent.com/Miosa-osa/OSA/main/scripts/install.ps1 | iex
osa
```

That installs OSA into `~/.osa` and adds the `osa` command. Running `osa` the first time opens the setup wizard.

To update later, just run:

```bash
osa update
```

---

## 2. Connect a model (recommended: GLM via Ollama Cloud)

When you run `osa` for the first time, the setup wizard asks which provider to use. The recommended pick, and the one the maintainers run daily, is **Ollama Cloud with GLM-5.2**. It needs no GPU, no large downloads, and gives you a 1,000,000 token context window.

Here is why it is the easy button:
- No local GPU or model download. Ollama offloads the heavy work to its cloud.
- GLM-5.2 has a huge 1M token context, so OSA can hold a lot of your codebase at once.
- It is cheap and fast for everyday work.

### Steps

1. Install Ollama from [ollama.com](https://ollama.com) (a normal app install).
2. Sign in to Ollama. You have two options:
   - Sign in through the Ollama desktop app or with `ollama signin`. Once your local Ollama is signed in, it proxies cloud models for you and OSA needs no extra key.
   - Or create an Ollama key at [ollama.com/account/keys](https://ollama.com/account/keys) and paste it into the OSA wizard.
3. In the OSA setup wizard, choose **Ollama Cloud (recommended)**, then pick the model **`glm-5.2:cloud`** (marked recommended).
4. That is it. OSA is ready. Type a request and press Enter.

If you ever want to change the model or provider later, run `osa setup`, or use the `/model` command inside OSA.

---

## 3. Provider and model options

You are not locked into GLM. OSA supports many providers. Pick by what matters to you: cost, privacy, or quality.

| Provider | How to get in | Recommended model | Notes |
|---|---|---|---|
| **Ollama Cloud** (recommended) | Sign in to Ollama, or key at ollama.com/account/keys | `glm-5.2:cloud` | No GPU, 1M context, cheap. Best starting point. |
| Ollama Cloud (alternatives) | Same as above | `glm-5.1:cloud`, `kimi-k2.7-code:cloud`, `minimax-m3:cloud` | Other strong cloud models, no GPU. |
| OpenRouter | Key at [openrouter.ai/keys](https://openrouter.ai/keys) | `z-ai/glm-4.6` | One key, many models through a single gateway. |
| Anthropic | Key at [console.anthropic.com](https://console.anthropic.com/settings/keys) | Claude Sonnet / Opus | Top tier quality, paid per use. |
| Ollama (fully local) | Install Ollama, no key | `nemotron-3-miosa` | Runs 100% on your machine. Needs a capable GPU or lots of RAM. Free and private. |
| z.ai / Zhipu (direct) | Key at z.ai, set `ZHIPU_API_KEY` | `glm-4.6`, `glm-5.2` | GLM straight from the vendor API. Advanced, set via env. |
| OpenAI | Key from OpenAI | GPT models | Standard OpenAI API. |
| Groq | Key from Groq | Fast inference | Very fast responses. |
| DeepSeek | Key from DeepSeek | DeepSeek models | Cost effective. |

### Context windows worth knowing

- `glm-5.2` / `glm-5.2:cloud`: 1,000,000 tokens
- `glm-5`: 200,000
- `glm-4.6`: 200,000
- Claude models: large, provider dependent

A bigger context window means OSA can keep more of your project in mind at once.

---

## 4. Using OSA

Launch it any time with:

```bash
osa
```

You get a terminal interface (the TUI). Type what you want in plain language and press Enter. OSA figures out the work, runs the tools it needs (reading files, editing, running commands), and reports back.

A few things to know:

- **Newline in the composer:** press Shift+Enter (or Ctrl+J) to add a line without sending.
- **Paste a big block:** it collapses into a tidy `[Pasted text +N lines]` chip so the composer stays clean.
- **Permission modes (Shift+Tab):** cycle how much OSA can do on its own, from asking each time up to `overdrive` (full auto, runs tools without prompting). Overdrive asks for a one time confirmation the first time.
- **Slash commands:** type `/` to see them. Useful ones:
  - `/model` switch the active model
  - `/clear` clear the conversation and screen
  - `/coordinator` turn on lead mode, where OSA plans and delegates to sub-agents (delegation and messaging only)
  - `/goal` set an auto continue goal loop
  - `/update` update OSA to the latest release
  - `/help` list everything

- **Sub-agents:** for bigger jobs OSA can fan out to a team of specialist workers (a tester, a reviewer, a researcher, and more). You watch them work live and see what each one produced.

---

## 5. Updating

OSA tells you in the status bar when a newer release is available. To update:

```bash
osa update
```

Or run `/update` from inside OSA. It is rollback safe.

---

## 6. Troubleshooting

- **"Ollama not detected":** install it from [ollama.com](https://ollama.com), then re-run `osa setup`. For cloud models, make sure your local Ollama is signed in.
- **Model says it is unauthorized:** your key expired or was not saved. Run `osa setup` and paste it again.
- **Want to start fresh:** re-run `osa setup` to reselect a provider and model at any time.
- **Check your setup:** run `osa doctor` for a health check of your configuration.

---

## Where to next

- Run `osa` and just ask it to do something real in one of your projects.
- Try `/coordinator` on a large task and watch the team work.
- Read the full docs at the OSA website for tools, agents, and advanced configuration.

Welcome aboard.
