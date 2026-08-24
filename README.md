# ccp

Per-model shell commands for Claude Code, backed by OpenRouter.

```bash
ccp add deepseek deepseek/deepseek-v4-flash
ccp add grok x-ai/grok-4.6

deepseek        # Claude Code, running on DeepSeek
grok            # Claude Code, running on Grok
```

Profiles share `~/.claude` by default, so a session you start on one model resumes on another
with no copying — and your real `claude` login is untouched.

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
aren't looked up automatically and `ccp cost` prints the raw API response.

## Commands

```
ccp init [--rc <file>] [--shell zsh|bash]   set up key + shell wiring
ccp add <name> <slug>                       create a profile and its command
ccp set <name> <slug>                       change a profile's model
ccp context <name> [tokens|auto]            declare the model's context window
ccp rm <name> [--purge]                     delete a profile
ccp ls | show <name>                        list profiles / print one, resolved
ccp test <name>                             send a real request to the endpoint
ccp cost                                    OpenRouter balance and spend
ccp models [filter]                         list OpenRouter slugs
ccp key                                     replace the API key

ccp sessions [name] [--all]                 stored sessions for this directory
ccp migrate <name>|--all                    fold a profile's own store into ~/.claude
ccp isolate <name> | share <name>           move a profile between stores
ccp resume <from> <to> [id]                 copy one session between stores
ccp backup                                  tar up every config directory

ccp sync                                    regenerate the shell functions
ccp doctor                                  check the setup
```

`add` takes `--label`, `--context`, `--isolated`, and `--opus`/`--sonnet`/`--haiku` to point the
aliases at different models. `--force` overrides the safety checks. `migrate` takes `--dry-run`
and `--keep-isolated`.

## Shared or isolated

By default every profile writes to `~/.claude`, so all your sessions land in one place. Switching
model mid-thread is just:

```bash
grok                                    # work, note the session id, exit
deepseek --resume <session-id>
```

One CLAUDE.md, one set of skills, hooks and MCP servers, one session picker. `ccp sessions`
lists what's stored for the current directory when you need an id.

`ccp add --isolated <name> <slug>` gives a profile its own `~/.claude-<name>` instead — separate
history, separate settings, nothing shared. Useful for a genuinely separate workstream, not for
routine model switching. `ccp isolate` and `ccp share` flip an existing profile; `ccp ls` shows
which mode each one is in.

Moving an isolated profile's sessions into the shared store:

```bash
ccp migrate --all --dry-run     # what would move, and any collisions
ccp migrate --all               # backs up first, then merges
```

Migration copies `projects/` only. Settings, history and trust state stay where they are, so the
shared directory asks you to trust each workspace once. Old config directories are left intact —
delete them yourself when you're satisfied. Anything already copied isn't copied twice.

## What it handles for you

**Alias models.** OpenRouter has no equivalent of Claude Code's `opus`/`sonnet`/`haiku` aliases.
Left unset, background tasks call a Claude model ID your gateway can't route. Profiles pin all
three.

**Context windows.** Claude Code assumes 200k for model IDs it doesn't recognise and
auto-compacts there, even on a 1M-token model. `ccp` reads the real window from OpenRouter and
writes `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, which takes plain integers between 100000 and 1000000.
Values outside that range are clamped with a warning: a 1M-token model compacts a few percent
early, and a model under 100k can't be lowered at all. `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is
written alongside it pending verification of which one your build honours.

**Session IDs.** Claude Code resolves a session id only when exactly one project holds it, so a
duplicate makes `--resume` report not-found rather than picking one. `migrate`, `resume` and
`doctor` all scan for that before writing anything.

**Slug typos.** Slugs are checked against OpenRouter's catalogue before a profile is written.
Retired IDs at some providers silently redirect and bill at another model's rate rather than
erroring, so a typo is not always loud.

**Name collisions.** `ccp add ls` is refused rather than shadowing `/usr/bin/ls`. In zsh, an
existing alias with a profile's name would break the function definition outright, so the
generated file unaliases first.

**Key rotation.** One key file, mode 600, sourced by every profile. `ccp key` replaces it once.
`ccp show` prints the resolved environment with the token masked.

## Files

```
~/.config/cc-profiles/
  _openrouter.key      the API key (600)
  <name>.env           one file per profile
  functions.sh         generated; sourced by your shell
  completion.zsh       generated; zsh completion for ccp
  backups/             tarballs written by ccp backup and ccp migrate
~/.claude/             shared sessions, history and settings
~/.claude-<name>/      an isolated profile's own copy of all that
```

Profile `.env` files are yours to edit. `ccp set` only follows the primary slug where a value was
actually tracking it, so a hand-set `--label` or per-tier override survives a model change. The
block between the `ccp context` markers is rewritten wholesale; everything else is left alone.
Run `ccp sync` after editing profiles by hand.

`ccp rm` never touches `~/.claude`. `--purge` deletes an isolated profile's directory and is
refused on a shared one.

## Costs

`/cost` and `/usage` price token counts against Anthropic's rates for Claude model IDs. Your
OpenRouter slugs aren't in that table, so the figure shown is not what you're being charged.

`ccp cost` reads the authoritative number from OpenRouter — credits purchased, used, remaining.
It's account-wide rather than per-session, so diff it either side of a run.

## Other providers

Profiles default to OpenRouter. To use a provider with its own Anthropic-compatible endpoint —
DeepSeek (`https://api.deepseek.com/anthropic`), Moonshot, Z.ai, a local LiteLLM — edit
`ANTHROPIC_BASE_URL` in the profile and swap the key line. `ccp test` still works;
`ccp models`, `ccp cost` and the context lookup don't.

Providers that only serve OpenAI-shaped `/v1/chat/completions` (xAI direct, OpenAI, Gemini,
most local servers) need a translating proxy. Reaching them through OpenRouter avoids that.

Consumer chat subscriptions — SuperGrok, ChatGPT Plus, Gemini Advanced — are not API access
and can't be used here.

## Caveats

Some Claude Code features are unavailable behind a custom base URL, including Remote Control
and, by default, MCP tool search. Prompt caching behaviour varies by provider. Tool-calling
reliability is model-dependent: weaker models mangle file edits or loop. Test a new model on a
real multi-step task, not a greeting.

Sharing a store makes a session *findable* from any profile; it doesn't guarantee the next model
will accept it. A transcript carrying one provider's thinking blocks and signed reasoning can be
rejected on the first turn. Test a provider pair on a throwaway session before relying on it
mid-task, and remember a resumed session keeps the model it was saved with unless you pass
`--model`.

Transcripts are an internal format that changes between releases. `ccp` copies whole files and
never edits them, but this is still unsupported ground — hence the backup before every migration.

## License

MIT
