# ccp

Per-model shell commands for Claude Code, backed by OpenRouter.

```bash
ccp add deepseek deepseek/deepseek-v4-flash
ccp add grok x-ai/grok-4.6

deepseek        # Claude Code, running on DeepSeek
grok            # Claude Code, running on Grok
```

Each profile gets its own config directory, so sessions, history and settings never mix — and
your real `claude` login is untouched.

## Why

Claude Code reads `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_MODEL` to decide
where requests go. Pointing them at OpenRouter works, but doing it by hand means a wrapper
function and an env file per model, plus a few non-obvious variables you only learn about after
they bite you. `ccp` writes those files and keeps them correct.

## Install

```bash
curl -o ~/.local/bin/ccp https://raw.githubusercontent.com/H4R335HR/ccp/main/ccp
chmod +x ~/.local/bin/ccp
ccp init
```

`ccp init` asks for your OpenRouter key and appends one line to your `~/.zshrc` or `~/.bashrc`.
That line is added once; adding models later doesn't touch your rc file again.

Requires `bash`, `curl`, and Claude Code. `python3` is optional — without it, context windows
aren't looked up automatically.

## Commands

```
ccp init [--rc <file>] [--shell zsh|bash]   set up key + shell wiring
ccp add <name> <slug>                       create a profile and its command
ccp set <name> <slug>                       change a profile's model
ccp context <name> [tokens|auto]            declare the model's context window
ccp rm <name> [--purge]                     delete a profile
ccp ls | show <name>                        list profiles / print one
ccp test <name>                             send a real request to the endpoint
ccp models [filter]                         list OpenRouter slugs
ccp key                                     replace the API key
ccp sync                                    regenerate the shell functions
ccp doctor                                  check the setup
```

`add` takes `--label`, `--context`, and `--opus`/`--sonnet`/`--haiku` to point the aliases at
different models. `--force` overrides the safety checks.

## What it handles for you

**Alias models.** OpenRouter has no equivalent of Claude Code's `opus`/`sonnet`/`haiku` aliases.
Left unset, background tasks call a Claude model ID your gateway can't route. Profiles pin all
three.

**Context windows.** Claude Code assumes 200k for model IDs it doesn't recognise and
auto-compacts there, even on a 1M-token model. `ccp` reads the real window from OpenRouter and
declares it with `CLAUDE_CODE_MAX_CONTEXT_TOKENS`.

**Slug typos.** Slugs are checked against OpenRouter's catalogue before a profile is written.
Retired IDs at some providers silently redirect and bill at another model's rate rather than
erroring, so a typo is not always loud.

**Name collisions.** `ccp add ls` is refused rather than shadowing `/usr/bin/ls`. In zsh, an
existing alias with a profile's name would break the function definition outright, so the
generated file unaliases first.

**Key rotation.** One key file, mode 600, sourced by every profile. `ccp key` replaces it once.

## Files

```
~/.config/cc-profiles/
  _openrouter.key      the API key (600)
  <name>.env           one file per profile
  functions.sh         generated; sourced by your shell
  completion.zsh       generated; zsh completion for ccp
~/.claude-<name>/      that profile's sessions, history and settings
```

Profile `.env` files are yours to edit — `ccp set` only rewrites the model lines, so any tuning
you add survives. Run `ccp sync` after editing profiles by hand.

`ccp rm` keeps `~/.claude-<name>` by default; `--purge` deletes it.

## Other providers

Profiles default to OpenRouter. To use a provider with its own Anthropic-compatible endpoint —
DeepSeek (`https://api.deepseek.com/anthropic`), Moonshot, Z.ai, a local LiteLLM — edit
`ANTHROPIC_BASE_URL` in the profile and swap the key line. `ccp test` still works;
`ccp models` and the context lookup don't.

Providers that only serve OpenAI-shaped `/v1/chat/completions` (xAI direct, OpenAI, Gemini,
most local servers) need a translating proxy. Reaching them through OpenRouter avoids that.

Consumer chat subscriptions — SuperGrok, ChatGPT Plus, Gemini Advanced — are not API access
and can't be used here.

## Caveats

Some Claude Code features are unavailable behind a custom base URL, including Remote Control
and, by default, MCP tool search. Prompt caching behaviour varies by provider. Tool-calling
reliability is model-dependent: weaker models mangle file edits or loop. Test a new model on a
real multi-step task, not a greeting.

Cost figures in `/cost` are priced against Anthropic's rates and will be wrong. Use the
OpenRouter dashboard.

## License

MIT
