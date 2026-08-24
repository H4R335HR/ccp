#!/usr/bin/env bash
# ccp — Claude Code profile manager for OpenRouter (and any Anthropic-compatible endpoint)
#
#   ccp init                    one-time setup: store key, wire up shell
#                               (--rc <file> / --shell zsh|bash to override detection)
#   ccp add <name> <slug>       create profile + shell command
#   ccp set <name> <slug>       change the model of an existing profile
#   ccp context <name> [n|auto] declare the model's real context window
#   ccp rm  <name> [--purge]    delete profile (--purge also deletes its config dir)
#   ccp ls                      list profiles
#   ccp show <name>             print a profile
#   ccp test <name>             live request against the endpoint
#   ccp key                     set/replace the OpenRouter API key
#   ccp models [filter]         list slugs available on OpenRouter
#   ccp sync                    regenerate the shell functions file
#   ccp doctor                  check the setup
#
set -euo pipefail

CC_PROFILE_DIR="${CC_PROFILE_DIR:-$HOME/.config/cc-profiles}"
KEY_FILE="$CC_PROFILE_DIR/_openrouter.key"
FUNC_FILE="$CC_PROFILE_DIR/functions.sh"
DEFAULT_BASE_URL="https://openrouter.ai/api"
MODELS_URL="https://openrouter.ai/api/v1/models"

# ---------------------------------------------------------------- utilities

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

die()  { c_red "ccp: $*" >&2; exit 1; }
warn() { c_yel "ccp: $*" >&2; }

profile_file() { printf '%s/%s.env\n' "$CC_PROFILE_DIR" "$1"; }
config_dir()   { printf '%s/.claude-%s\n' "$HOME" "$1"; }

ensure_dir() {
  mkdir -p "$CC_PROFILE_DIR"
  chmod 700 "$CC_PROFILE_DIR"
}

valid_name() {
  case "$1" in
    [a-zA-Z]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!a-zA-Z0-9_-]*) return 1 ;;
  esac
  return 0
}

profile_names() {
  [ -d "$CC_PROFILE_DIR" ] || return 0
  for f in "$CC_PROFILE_DIR"/*.env; do
    [ -e "$f" ] || continue
    b=$(basename "$f" .env)
    case "$b" in _*) continue ;; esac
    printf '%s\n' "$b"
  done
}

read_var() { # read_var <file> <VARNAME>
  ( set +u; set -a; . "$1" >/dev/null 2>&1; set +a; eval "printf '%s' \"\${$2:-}\"" )
}

# ------------------------------------------------------------------- key

cmd_key() {
  ensure_dir
  local key="${1:-}"
  if [ -z "$key" ]; then
    printf 'OpenRouter API key (sk-or-v1-...): '
    read -r -s key
    printf '\n'
  fi
  [ -n "$key" ] || die "no key given"
  case "$key" in
    sk-or-*) ;;
    *) warn "that doesn't look like an OpenRouter key — storing it anyway" ;;
  esac
  umask 077
  printf 'ANTHROPIC_AUTH_TOKEN="%s"\n' "$key" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  c_grn "key stored in $KEY_FILE (mode 600)"
}

get_key() {
  [ -r "$KEY_FILE" ] || die "no key stored — run: ccp key"
  read_var "$KEY_FILE" ANTHROPIC_AUTH_TOKEN
}

# ---------------------------------------------------------------- models

fetch_models() {
  command -v curl >/dev/null 2>&1 || die "curl not found"
  curl -fsSL --max-time 20 "$MODELS_URL" 2>/dev/null || return 1
}

slug_exists() { # best-effort; returns 0 unknown-but-ok if the API is unreachable
  local slug="$1" body
  body=$(fetch_models) || { warn "couldn't reach OpenRouter to verify the slug — continuing"; return 0; }
  printf '%s' "$body" | grep -q "\"id\"[[:space:]]*:[[:space:]]*\"$slug\"" && return 0
  return 1
}

slug_context() { # prints the model's real context window in tokens, or nothing
  local slug="$1" body
  command -v python3 >/dev/null 2>&1 || return 0
  body=$(fetch_models) || return 0
  printf '%s' "$body" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
want = sys.argv[1]
for m in data.get("data", []):
    if m.get("id") == want:
        n = m.get("context_length") or (m.get("top_provider") or {}).get("context_length")
        if isinstance(n, int) and n > 0:
            print(n)
        break
' "$slug" 2>/dev/null || true
}

cmd_models() {
  local filter="${1:-}" body
  body=$(fetch_models) || die "couldn't reach OpenRouter"
  printf '%s' "$body" \
    | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"\([^"]*\)"$/\1/' \
    | sort -u \
    | { [ -n "$filter" ] && grep -i -- "$filter" || cat; }
}

# --------------------------------------------------------------- profiles

write_profile() { # write_profile <name> <slug> [opus] [sonnet] [haiku] [label] [ctx]
  local name="$1" slug="$2"
  local opus="${3:-$slug}" sonnet="${4:-$slug}" haiku="${5:-$slug}"
  local label="${6:-$slug}" ctx="${7:-}"
  local f; f=$(profile_file "$name")
  umask 077
  cat > "$f" <<EOF
# ~/.config/cc-profiles/$name.env — managed by ccp, safe to hand-edit
. "\${CC_PROFILE_DIR:-\$HOME/.config/cc-profiles}/_openrouter.key"

ANTHROPIC_BASE_URL="$DEFAULT_BASE_URL"
ANTHROPIC_API_KEY=""

ANTHROPIC_MODEL="$slug"
ANTHROPIC_DEFAULT_OPUS_MODEL="$opus"
ANTHROPIC_DEFAULT_SONNET_MODEL="$sonnet"
ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku"

ANTHROPIC_CUSTOM_MODEL_OPTION="$slug"
ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="$label"

CLAUDE_CODE_ATTRIBUTION_HEADER="0"
API_TIMEOUT_MS="1200000"
EOF
  if [ -n "$ctx" ]; then
    cat >> "$f" <<EOF

# Claude Code assumes 200k for model IDs it doesn't know, which makes auto-compact
# fire early. This declares the real window (read from OpenRouter on $(date -u '+%Y-%m-%d')).
CLAUDE_CODE_MAX_CONTEXT_TOKENS="$ctx"
EOF
  fi
  chmod 600 "$f"
}

cmd_add() {
  ensure_dir
  local name="" slug="" label="" force=0 opus="" sonnet="" haiku="" ctx=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)   force=1; shift ;;
      --label)   label="$2"; shift 2 ;;
      --opus)    opus="$2"; shift 2 ;;
      --sonnet)  sonnet="$2"; shift 2 ;;
      --haiku)   haiku="$2"; shift 2 ;;
      --context) ctx="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) if [ -z "$name" ]; then name="$1"; elif [ -z "$slug" ]; then slug="$1"; else die "too many arguments"; fi; shift ;;
    esac
  done

  [ -n "$name" ] || { printf 'command name (e.g. grok): '; read -r name; }
  valid_name "$name" || die "'$name' is not a usable shell command name (letters, digits, _ and -, must start with a letter)"

  [ -n "$slug" ] || { printf 'OpenRouter model slug (e.g. x-ai/grok-4.6): '; read -r slug; }
  [ -n "$slug" ] || die "no slug given"

  [ -r "$KEY_FILE" ] || cmd_key

  if [ -e "$(profile_file "$name")" ] && [ "$force" -eq 0 ]; then
    die "profile '$name' already exists — use 'ccp set $name <slug>' or 'ccp add --force'"
  fi

  # don't silently shadow a real command
  if [ "$force" -eq 0 ] && command -v "$name" >/dev/null 2>&1; then
    case "$(type -t "$name" 2>/dev/null || echo)" in
      function) : ;;
      *) die "'$name' is already a command on your PATH ($(command -v "$name")) — pick another name or pass --force" ;;
    esac
  fi

  # zsh aliases aren't visible from here; best-effort grep of the rc file
  if grep -Eq "^[[:space:]]*alias[[:space:]]+$name=" "$(rc_file)" 2>/dev/null; then
    warn "'$name' is also an alias in $(rc_file) — the generated functions file unaliases it, so the profile wins"
  fi

  if ! slug_exists "$slug"; then
    warn "OpenRouter doesn't list '$slug'."
    printf 'create the profile anyway? [y/N] '
    read -r ans
    case "$ans" in y|Y|yes) ;; *) die "aborted — try: ccp models ${slug%%/*}" ;; esac
  fi

  [ -n "$ctx" ] || ctx=$(slug_context "$slug")
  write_profile "$name" "$slug" "${opus:-$slug}" "${sonnet:-$slug}" "${haiku:-$slug}" "${label:-$slug}" "$ctx"
  cmd_sync quiet
  c_grn "added '$name' → $slug"
  c_dim "  profile:    $(profile_file "$name")"
  c_dim "  config dir: $(config_dir "$name")"
  if [ -n "$ctx" ]; then
    c_dim "  context:    $ctx tokens (declared, so auto-compact doesn't fire at 200k)"
  else
    c_yel "  context:    unknown — Claude Code will assume 200k and compact early."
    c_dim "              Set the real window with: ccp context $name <tokens>"
  fi
  post_sync_hint
}

cmd_context() {
  local name="${1:-}" ctx="${2:-}"
  [ -n "$name" ] || die "usage: ccp context <name> [tokens|auto]"
  local f; f=$(profile_file "$name")
  [ -e "$f" ] || die "no profile '$name'"
  local slug; slug=$(read_var "$f" ANTHROPIC_MODEL)

  if [ -z "$ctx" ] || [ "$ctx" = auto ]; then
    ctx=$(slug_context "$slug")
    [ -n "$ctx" ] || die "OpenRouter didn't report a context length for '$slug' — pass the number explicitly"
    c_dim "OpenRouter reports $ctx tokens for $slug"
  fi
  case "$ctx" in
    ''|*[!0-9]*) die "context must be a plain token count, e.g. 1000000" ;;
  esac

  local tmp; tmp=$(mktemp)
  grep -v '^CLAUDE_CODE_MAX_CONTEXT_TOKENS=' "$f" > "$tmp"
  printf 'CLAUDE_CODE_MAX_CONTEXT_TOKENS="%s"\n' "$ctx" >> "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
  c_grn "$name: context window declared as $ctx tokens"
  c_dim "restart the session for it to take effect"
}

cmd_set() {
  local name="${1:-}" slug="${2:-}"
  [ -n "$name" ] || die "usage: ccp set <name> <slug>"
  local f; f=$(profile_file "$name")
  [ -e "$f" ] || die "no profile '$name'"
  [ -n "$slug" ] || { printf 'new model slug: '; read -r slug; }
  [ -n "$slug" ] || die "no slug given"

  if ! slug_exists "$slug"; then
    warn "OpenRouter doesn't list '$slug'."
    printf 'use it anyway? [y/N] '
    read -r ans
    case "$ans" in y|Y|yes) ;; *) die "aborted" ;; esac
  fi

  # rewrite only the model lines, preserve any hand-edits elsewhere
  local old; old=$(read_var "$f" ANTHROPIC_MODEL)
  local tmp; tmp=$(mktemp)
  sed -e "s|^ANTHROPIC_MODEL=.*|ANTHROPIC_MODEL=\"$slug\"|" \
      -e "s|^ANTHROPIC_DEFAULT_OPUS_MODEL=.*|ANTHROPIC_DEFAULT_OPUS_MODEL=\"$slug\"|" \
      -e "s|^ANTHROPIC_DEFAULT_SONNET_MODEL=.*|ANTHROPIC_DEFAULT_SONNET_MODEL=\"$slug\"|" \
      -e "s|^ANTHROPIC_DEFAULT_HAIKU_MODEL=.*|ANTHROPIC_DEFAULT_HAIKU_MODEL=\"$slug\"|" \
      -e "s|^ANTHROPIC_CUSTOM_MODEL_OPTION=.*|ANTHROPIC_CUSTOM_MODEL_OPTION=\"$slug\"|" \
      -e "s|^ANTHROPIC_CUSTOM_MODEL_OPTION_NAME=.*|ANTHROPIC_CUSTOM_MODEL_OPTION_NAME=\"$slug\"|" \
      "$f" > "$tmp"
  cat "$tmp" > "$f"   # preserve mode 600
  rm -f "$tmp"
  c_grn "$name: ${old:-?} → $slug"

  # the new model probably has a different window
  local ctx; ctx=$(slug_context "$slug")
  if [ -n "$ctx" ]; then
    tmp=$(mktemp)
    grep -v '^CLAUDE_CODE_MAX_CONTEXT_TOKENS=' "$f" > "$tmp"
    printf 'CLAUDE_CODE_MAX_CONTEXT_TOKENS="%s"\n' "$ctx" >> "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
    c_dim "context window updated to $ctx tokens"
  else
    c_yel "context window unknown for the new model — check with: ccp context $name auto"
  fi
  c_dim "restart any running '$name' session for this to take effect"
}

cmd_rm() {
  local name="" purge=0 yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1; shift ;;
      -y|--yes) yes=1; shift ;;
      -*) die "unknown option: $1" ;;
      *) name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: ccp rm <name> [--purge]"
  local f; f=$(profile_file "$name")
  [ -e "$f" ] || die "no profile '$name'"

  local dir; dir=$(config_dir "$name")
  if [ "$yes" -eq 0 ]; then
    printf 'delete profile %s' "$name"
    [ "$purge" -eq 1 ] && [ -d "$dir" ] && printf ' AND its sessions in %s' "$dir"
    printf '? [y/N] '
    read -r ans
    case "$ans" in y|Y|yes) ;; *) die "aborted" ;; esac
  fi

  rm -f "$f"
  if [ "$purge" -eq 1 ] && [ -d "$dir" ]; then
    rm -rf "$dir"
    c_dim "removed $dir"
  elif [ -d "$dir" ]; then
    c_dim "kept $dir (sessions/history) — remove with: rm -rf '$dir'"
  fi
  cmd_sync quiet
  c_grn "removed '$name'"
  post_sync_hint
}

cmd_ls() {
  local any=0
  while read -r n; do
    [ -n "$n" ] || continue
    any=1
    printf '%-14s %s\n' "$n" "$(read_var "$(profile_file "$n")" ANTHROPIC_MODEL)"
  done <<EOF
$(profile_names)
EOF
  [ "$any" -eq 1 ] || c_dim "no profiles yet — try: ccp add deepseek deepseek/deepseek-v4-flash"
}

cmd_show() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: ccp show <name>"
  local f; f=$(profile_file "$name")
  [ -e "$f" ] || die "no profile '$name'"
  sed 's/^\(ANTHROPIC_AUTH_TOKEN=\).*/\1"<redacted>"/' "$f"
}

# ------------------------------------------------------------------ test

cmd_test() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: ccp test <name>"
  local f; f=$(profile_file "$name")
  [ -e "$f" ] || die "no profile '$name'"
  command -v curl >/dev/null 2>&1 || die "curl not found"

  local base model key code body tmp
  base=$(read_var "$f" ANTHROPIC_BASE_URL)
  model=$(read_var "$f" ANTHROPIC_MODEL)
  key=$(get_key)
  tmp=$(mktemp)

  printf 'POST %s/v1/messages  [%s] ... ' "$base" "$model"
  code=$(curl -s -o "$tmp" -w '%{http_code}' --max-time 60 \
    -X POST "$base/v1/messages" \
    -H "Authorization: Bearer $key" \
    -H "content-type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "{\"model\":\"$model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"reply with the single word: ok\"}]}" \
    || echo 000)
  body=$(cat "$tmp"); rm -f "$tmp"

  case "$code" in
    200) c_grn "$code OK"; c_dim "  $(printf '%s' "$body" | head -c 300)" ;;
    401|403) c_red "$code auth rejected"
             c_dim "  key wrong, or this endpoint wants 'x-api-key' instead of a bearer token" ;;
    404) c_red "$code not found"
         c_dim "  base URL has a trailing slash or an extra /v1, or the endpoint isn't Anthropic-shaped" ;;
    400) c_red "$code bad request"
         c_dim "  usually an unknown model slug: $(printf '%s' "$body" | head -c 200)" ;;
    000) c_red "no response (timeout / DNS / offline)" ;;
    *)   c_red "$code"; c_dim "  $(printf '%s' "$body" | head -c 300)" ;;
  esac
}

# ------------------------------------------------------------------ sync

cmd_sync() {
  ensure_dir
  local quiet="${1:-}"
  umask 077
  {
    echo "# AUTO-GENERATED by ccp on $(date -u '+%Y-%m-%dT%H:%M:%SZ') — do not edit by hand."
    echo "# Regenerate with: ccp sync.  Sourced by both bash and zsh — keep it POSIX-ish."
    echo
    echo "CC_PROFILE_DIR=\"\${CC_PROFILE_DIR:-\$HOME/.config/cc-profiles}\""
    echo
    echo "# zsh expands aliases at parse time, so an alias sharing a profile's name would"
    echo "# break the function definitions below. Clear any collisions first."
    while read -r n; do
      [ -n "$n" ] || continue
      printf 'unalias %s >/dev/null 2>&1 || true\n' "$n"
    done <<EOF
$(profile_names)
EOF
    echo
    cat <<'BODY'
__ccp_launch() {
  local name="$1"; shift
  local f="$CC_PROFILE_DIR/$name.env"
  if [ ! -r "$f" ]; then
    echo "ccp: no profile '$name' ($f)" >&2
    return 1
  fi
  ( set -a; . "$f"; set +a
    CLAUDE_CONFIG_DIR="$HOME/.claude-$name" command claude "$@" )
}
BODY
    echo
    while read -r n; do
      [ -n "$n" ] || continue
      printf '%s() { __ccp_launch %s "$@"; }\n' "$n" "$n"
    done <<EOF
$(profile_names)
EOF
    echo
    cat <<'BODY'
# zsh-only completion lives in its own file so bash never has to parse zsh syntax.
if [ -n "${ZSH_VERSION:-}" ] && [ -r "$CC_PROFILE_DIR/completion.zsh" ]; then
  . "$CC_PROFILE_DIR/completion.zsh"
fi
BODY
  } > "$FUNC_FILE"
  chmod 600 "$FUNC_FILE"
  write_zsh_completion
  [ "$quiet" = quiet ] || c_grn "wrote $FUNC_FILE"
}

write_zsh_completion() {
  umask 077
  cat > "$CC_PROFILE_DIR/completion.zsh" <<'ZBODY'
# AUTO-GENERATED by ccp — zsh completion for the ccp command.
if whence compdef >/dev/null 2>&1; then
  _ccp() {
    local -a subcmds profiles
    subcmds=(init add set context rm ls show test key models sync doctor help)
    if (( CURRENT == 2 )); then
      compadd -- $subcmds
      return
    fi
    case ${words[2]} in
      set|context|ctx|rm|remove|del|delete|show|cat|test)
        profiles=(${${(f)"$(print -l ${CC_PROFILE_DIR:-$HOME/.config/cc-profiles}/*.env(N:t:r))"}:#_*})
        (( CURRENT == 3 )) && compadd -- $profiles
        ;;
    esac
  }
  compdef _ccp ccp
fi
ZBODY
  chmod 600 "$CC_PROFILE_DIR/completion.zsh"
}

post_sync_hint() {
  local rc; rc=$(rc_file)
  if [ -n "$rc" ] && grep -q "cc-profiles/functions.sh" "$rc" 2>/dev/null; then
    c_dim "run 'source $rc' (or open a new shell) to pick it up"
  else
    c_yel "not wired into your shell yet — run: ccp init"
  fi
}

rc_file() {
  if [ -n "${CCP_RC:-}" ]; then printf '%s\n' "$CCP_RC"; return; fi
  local zdir="${ZDOTDIR:-$HOME}"
  case "${CCP_SHELL:-${SHELL##*/}}" in
    zsh)  printf '%s/.zshrc\n'  "$zdir" ;;
    bash) printf '%s/.bashrc\n' "$HOME" ;;
    *)    if [ -f "$zdir/.zshrc" ]; then printf '%s/.zshrc\n' "$zdir"; else printf '%s/.bashrc\n' "$HOME"; fi ;;
  esac
}

# ------------------------------------------------------------------ init

cmd_init() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --rc)    CCP_RC="$2"; shift 2 ;;
      --shell) CCP_SHELL="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  ensure_dir
  [ -r "$KEY_FILE" ] || cmd_key
  cmd_sync quiet

  local rc line; rc=$(rc_file)
  [ -e "$rc" ] || { : > "$rc"; c_dim "created $rc"; }
  line='[ -f "$HOME/.config/cc-profiles/functions.sh" ] && . "$HOME/.config/cc-profiles/functions.sh"'
  if grep -qF 'cc-profiles/functions.sh' "$rc" 2>/dev/null; then
    c_dim "$rc already sources the profile functions"
  else
    printf '\n# Claude Code model profiles (ccp)\n%s\n' "$line" >> "$rc"
    c_grn "appended the loader to $rc"
  fi
  c_grn "ready."
  c_dim "  source $rc"
  c_dim "  ccp add deepseek deepseek/deepseek-v4-flash"
}

# ---------------------------------------------------------------- doctor

cmd_doctor() {
  local ok=0
  chk() { if eval "$2" >/dev/null 2>&1; then c_grn "  ok    $1"; else c_red "  FAIL  $1"; ok=1; fi; }
  echo "environment:"
  chk "curl installed"                "command -v curl"
  chk "claude on PATH"                "command -v claude"
  echo "setup:"
  chk "profile dir $CC_PROFILE_DIR"   "[ -d '$CC_PROFILE_DIR' ]"
  chk "api key stored"                "[ -r '$KEY_FILE' ]"
  chk "functions file generated"      "[ -r '$FUNC_FILE' ]"
  chk "shell rc sources functions"    "grep -qF cc-profiles/functions.sh '$(rc_file)'"
  echo "permissions:"
  if [ -r "$KEY_FILE" ]; then
    local m; m=$(stat -c '%a' "$KEY_FILE" 2>/dev/null || stat -f '%A' "$KEY_FILE" 2>/dev/null || echo '?')
    [ "$m" = 600 ] && c_grn "  ok    key file is $m" || c_yel "  warn  key file is $m (want 600)"
  fi
  echo "profiles:"
  cmd_ls | sed 's/^/  /'
  local n
  while read -r n; do
    [ -n "$n" ] || continue
    if ! grep -q '^CLAUDE_CODE_MAX_CONTEXT_TOKENS=' "$(profile_file "$n")" 2>/dev/null; then
      c_yel "  warn  $n has no declared context window (Claude Code will assume 200k)"
    fi
  done <<EOF
$(profile_names)
EOF
  return $ok
}

# ------------------------------------------------------------------ main

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/,""); print; next } NR>1 { exit }' "$0"; }

case "${1:-}" in
  init)    shift; cmd_init "$@" ;;
  add)     shift; cmd_add "$@" ;;
  set|update) shift; cmd_set "$@" ;;
  context|ctx) shift; cmd_context "$@" ;;
  rm|remove|del|delete) shift; cmd_rm "$@" ;;
  ls|list) shift; cmd_ls "$@" ;;
  show|cat) shift; cmd_show "$@" ;;
  test)    shift; cmd_test "$@" ;;
  key)     shift; cmd_key "$@" ;;
  models)  shift; cmd_models "$@" ;;
  sync)    shift; cmd_sync "$@" ;;
  doctor)  shift; cmd_doctor "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command '$1' — try: ccp --help" ;;
esac
