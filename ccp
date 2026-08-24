#!/usr/bin/env bash
# ccp — Claude Code profile manager for OpenRouter (and any Anthropic-compatible endpoint)
#
#   ccp init                    one-time setup: store key, wire up shell
#                               (--rc <file> / --shell zsh|bash to override detection)
#   ccp add <name> <slug>       create profile + shell command (--isolated for its own config dir)
#   ccp set <name> <slug>       change the model of an existing profile
#   ccp context <name> [n|auto] declare the model's real context window
#   ccp rm  <name> [--purge]    delete profile (--purge also deletes an isolated config dir)
#   ccp ls                      list profiles
#   ccp show <name>             print a profile and its resolved environment
#   ccp test <name>             live request against the endpoint
#   ccp key                     set/replace the OpenRouter API key
#   ccp cost                    OpenRouter credit balance and spend
#   ccp models [filter]         list slugs available on OpenRouter
#
#   ccp sessions [name] [--all] list stored sessions for this directory
#   ccp migrate <name>|--all    fold an isolated profile's sessions into ~/.claude
#                               (--dry-run to preview, --keep-isolated to copy but stay isolated)
#   ccp isolate <name>          give a profile its own config dir
#   ccp share <name>            put a profile back on the shared ~/.claude
#   ccp resume <from> <to> [id] copy one session between two profiles' stores
#   ccp backup                  tar up ~/.claude and every ~/.claude-* config dir
#
#   ccp sync                    regenerate the shell functions file
#   ccp doctor                  check the setup
#
set -euo pipefail

CC_PROFILE_DIR="${CC_PROFILE_DIR:-$HOME/.config/cc-profiles}"
KEY_FILE="$CC_PROFILE_DIR/_openrouter.key"
FUNC_FILE="$CC_PROFILE_DIR/functions.sh"
BACKUP_DIR="$CC_PROFILE_DIR/backups"
SHARED_ROOT="$HOME/.claude"
DEFAULT_BASE_URL="https://openrouter.ai/api"
MODELS_URL="https://openrouter.ai/api/v1/models"
CREDITS_URL="https://openrouter.ai/api/v1/credits"

# Documented range for CLAUDE_CODE_AUTO_COMPACT_WINDOW.
CTX_EFFECTIVE=""
CTX_MIN=100000
CTX_MAX=1000000

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

set_var() { # set_var <file> <NAME> <value> — replaces in place, appends if absent
  local f="$1" k="$2" v="$3" tmp
  tmp=$(mktemp)
  if grep -q "^$k=" "$f" 2>/dev/null; then
    sed "s|^$k=.*|$k=\"$v\"|" "$f" > "$tmp"
  else
    cat "$f" > "$tmp"
    printf '%s="%s"\n' "$k" "$v" >> "$tmp"
  fi
  cat "$tmp" > "$f"   # preserve mode 600
  rm -f "$tmp"
}

unset_var() { # unset_var <file> <NAME>
  local f="$1" k="$2" tmp
  tmp=$(mktemp)
  grep -v "^$k=" "$f" > "$tmp" || true
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

need_profile() { # need_profile <name> — prints the profile path or dies
  local name="${1:-}" f
  [ -n "$name" ] || die "no profile name given"
  f=$(profile_file "$name")
  [ -e "$f" ] || die "no profile '$name'"
  printf '%s\n' "$f"
}

# coreutils 9.3+ warns that `cp -n` is non-portable; use the new spelling there.
CP_NC=""
cp_nc() { # cp_nc <src...> <dst> — recursive copy that never overwrites
  if [ -z "$CP_NC" ]; then
    if cp --help 2>/dev/null | grep -q -- '--update\[='; then CP_NC="--update=none"; else CP_NC="-n"; fi
  fi
  cp -a "$CP_NC" "$@"
}

# ------------------------------------------------------- isolation / storage

is_isolated() { # is_isolated <name>
  local f; f=$(profile_file "$1")
  [ -e "$f" ] || return 1
  [ -n "$(read_var "$f" CCP_ISOLATED)" ]
}

storage_root() { # storage_root <name> — where this profile's sessions live
  if is_isolated "$1"; then config_dir "$1"; else printf '%s\n' "$SHARED_ROOT"; fi
}

project_key() { # project_key <abs-dir> — Claude Code's derived <project> name
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'
}

# Emit "<session-id>\t<project>\t<path>" for every transcript under a config dir.
scan_sessions() { # scan_sessions <config-dir>
  local root="$1" f p s
  [ -d "$root/projects" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    p=$(basename "$(dirname "$f")")
    s=$(basename "$f" .jsonl)
    printf '%s\t%s\t%s\n' "$s" "$p" "$f"
  done <<EOF
$(find "$root/projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' 2>/dev/null | sort)
EOF
}

# A session ID living under two different project names breaks --resume:
# Claude Code reports not-found rather than picking one. Refuse to create that.
check_cross_project() { # check_cross_project <listing-file>
  local dupes
  dupes=$(awk -F'\t' '
    { if (!($1 SUBSEP $2 in seen)) { seen[$1 SUBSEP $2]=1; n[$1]++; where[$1]=where[$1] "  " $2 } }
    END { for (s in n) if (n[s] > 1) printf "%s%s\n", s, where[s] }
  ' "$1")
  if [ -n "$dupes" ]; then
    c_red "ccp: the same session ID would exist under more than one project:" >&2
    printf '%s\n' "$dupes" >&2
    return 1
  fi
  return 0
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

mask() { # mask <secret>
  local s="$1" n=${#1}
  if [ "$n" -le 16 ]; then printf '%s\n' "<redacted>"; else
    printf '%s…%s\n' "${s:0:12}" "${s: -4}"
  fi
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

# ------------------------------------------------------------------- cost

cmd_cost() {
  local key body
  command -v curl >/dev/null 2>&1 || die "curl not found"
  key=$(get_key)
  body=$(curl -fsSL --max-time 20 "$CREDITS_URL" -H "Authorization: Bearer $key" 2>/dev/null) \
    || die "couldn't reach the OpenRouter credits endpoint"

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found — printing the raw response"
    printf '%s\n' "$body"
    return 0
  fi

  printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin).get("data", {})
except Exception:
    print("could not parse the response"); sys.exit(0)
t = float(d.get("total_credits", 0) or 0)
u = float(d.get("total_usage", 0) or 0)
print("purchased  $%.2f" % t)
print("used       $%.4f" % u)
print("remaining  $%.2f" % (t - u))
'
  c_dim "this is account-wide; Claude Code's own figure is priced from a Claude model table"
  c_dim "and does not know your OpenRouter slugs. Diff this before and after a session."
}

# --------------------------------------------------------------- profiles

write_profile() { # write_profile <name> <slug> <opus> <sonnet> <haiku> <label> <ctx> <isolated>
  local name="$1" slug="$2"
  local opus="${3:-$slug}" sonnet="${4:-$slug}" haiku="${5:-$slug}"
  local label="${6:-$slug}" ctx="${7:-}" isolated="${8:-}"
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
  chmod 600 "$f"
  [ -n "$isolated" ] && set_var "$f" CCP_ISOLATED "1"
  [ -n "$ctx" ] && write_context_block "$f" "$ctx"
  return 0
}

# Everything between the markers is rewritten wholesale, so repeated
# `ccp context` runs don't leave orphaned comments behind.
write_context_block() { # write_context_block <profile-file> <tokens>
  local f="$1" ctx="$2" clamped="$ctx" note="" tmp
  if [ "$ctx" -lt "$CTX_MIN" ]; then
    clamped="$CTX_MIN"
    note="the model's window is smaller than the ${CTX_MIN}-token floor, so this can't be lowered further"
  elif [ "$ctx" -gt "$CTX_MAX" ]; then
    clamped="$CTX_MAX"
    note="the model's window is larger than the ${CTX_MAX}-token ceiling, so compaction still fires early"
  fi

  tmp=$(mktemp)
  awk '/^# >>> ccp context/{s=1} !s{print} /^# <<< ccp context/{s=0}' "$f" \
    | grep -v '^CLAUDE_CODE_MAX_CONTEXT_TOKENS=' \
    | grep -v '^CLAUDE_CODE_AUTO_COMPACT_WINDOW=' \
    | awk '{ l[NR]=$0 } END { n=NR; while (n>0 && l[n] ~ /^[[:space:]]*$/) n--; for (i=1;i<=n;i++) print l[i] }' > "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"

  cat >> "$f" <<EOF

# >>> ccp context (managed) >>>
# Claude Code assumes 200k for model IDs it doesn't recognise, which makes
# auto-compact fire early. Real window: $ctx tokens (read from OpenRouter on $(date -u '+%Y-%m-%d')).
# AUTO_COMPACT_WINDOW is the documented knob and takes plain integers in
# $CTX_MIN..$CTX_MAX. MAX_CONTEXT_TOKENS is kept alongside it pending verification.
CLAUDE_CODE_AUTO_COMPACT_WINDOW="$clamped"
CLAUDE_CODE_MAX_CONTEXT_TOKENS="$ctx"
# <<< ccp context (managed) <<<
EOF

  CTX_EFFECTIVE="$clamped"
  [ -n "$note" ] && warn "$note"
  return 0
}

cmd_add() {
  ensure_dir
  local name="" slug="" label="" force=0 opus="" sonnet="" haiku="" ctx="" isolated=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)    force=1; shift ;;
      --isolated) isolated=1; shift ;;
      --label)    label="$2"; shift 2 ;;
      --opus)     opus="$2"; shift 2 ;;
      --sonnet)   sonnet="$2"; shift 2 ;;
      --haiku)    haiku="$2"; shift 2 ;;
      --context)  ctx="$2"; shift 2 ;;
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
  write_profile "$name" "$slug" "${opus:-$slug}" "${sonnet:-$slug}" "${haiku:-$slug}" "${label:-$slug}" "$ctx" "$isolated"
  cmd_sync quiet
  c_grn "added '$name' → $slug"
  c_dim "  profile:  $(profile_file "$name")"
  if [ -n "$isolated" ]; then
    c_dim "  storage:  $(config_dir "$name")  (isolated)"
  else
    c_dim "  storage:  $SHARED_ROOT  (shared)"
  fi
  if [ -n "$ctx" ]; then
    c_dim "  context:  $ctx tokens (declared, so auto-compact doesn't fire at 200k)"
  else
    c_yel "  context:  unknown — Claude Code will assume 200k and compact early."
    c_dim "            Set the real window with: ccp context $name <tokens>"
  fi
  post_sync_hint
}

cmd_context() {
  local name="${1:-}" ctx="${2:-}"
  [ -n "$name" ] || die "usage: ccp context <name> [tokens|auto]"
  local f; f=$(need_profile "$name")
  local slug; slug=$(read_var "$f" ANTHROPIC_MODEL)

  if [ -z "$ctx" ] || [ "$ctx" = auto ]; then
    ctx=$(slug_context "$slug")
    [ -n "$ctx" ] || die "OpenRouter didn't report a context length for '$slug' — pass the number explicitly"
    c_dim "OpenRouter reports $ctx tokens for $slug"
  fi
  case "$ctx" in
    ''|*[!0-9]*) die "context must be a plain token count, e.g. 1000000" ;;
  esac

  write_context_block "$f" "$ctx"
  if [ "$CTX_EFFECTIVE" = "$ctx" ]; then
    c_grn "$name: context window declared as $ctx tokens"
  else
    c_grn "$name: model window $ctx tokens; auto-compact window set to $CTX_EFFECTIVE (clamped)"
  fi
  c_dim "restart the session for it to take effect"
}

cmd_set() {
  local name="${1:-}" slug="${2:-}"
  [ -n "$name" ] || die "usage: ccp set <name> <slug>"
  local f; f=$(need_profile "$name")
  [ -n "$slug" ] || { printf 'new model slug: '; read -r slug; }
  [ -n "$slug" ] || die "no slug given"

  if ! slug_exists "$slug"; then
    warn "OpenRouter doesn't list '$slug'."
    printf 'use it anyway? [y/N] '
    read -r ans
    case "$ans" in y|Y|yes) ;; *) die "aborted" ;; esac
  fi

  local old cur k kept=""
  old=$(read_var "$f" ANTHROPIC_MODEL)
  set_var "$f" ANTHROPIC_MODEL "$slug"

  # Only follow the primary slug where the value was actually tracking it —
  # a hand-set --label or a per-tier override stays put.
  for k in ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
           ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_CUSTOM_MODEL_OPTION \
           ANTHROPIC_CUSTOM_MODEL_OPTION_NAME; do
    cur=$(read_var "$f" "$k")
    if [ "$cur" = "$old" ] || [ -z "$cur" ]; then
      set_var "$f" "$k" "$slug"
    else
      kept="$kept $k"
    fi
  done

  c_grn "$name: ${old:-?} → $slug"
  [ -n "$kept" ] && c_dim "  left alone (hand-set):$kept"

  local ctx; ctx=$(slug_context "$slug")
  if [ -n "$ctx" ]; then
    write_context_block "$f" "$ctx"
    c_dim "context window updated to $ctx tokens (auto-compact window $CTX_EFFECTIVE)"
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
  local f; f=$(need_profile "$name")

  local dir isolated=0
  dir=$(config_dir "$name")
  is_isolated "$name" && isolated=1

  if [ "$purge" -eq 1 ] && [ "$isolated" -eq 0 ]; then
    die "'$name' shares $SHARED_ROOT — --purge would delete every profile's sessions. Refusing."
  fi

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
  elif [ "$isolated" -eq 0 ]; then
    c_dim "sessions stay in $SHARED_ROOT alongside your other profiles"
  fi
  cmd_sync quiet
  c_grn "removed '$name'"
  post_sync_hint
}

cmd_ls() {
  local any=0 n mode
  while read -r n; do
    [ -n "$n" ] || continue
    any=1
    if is_isolated "$n"; then mode="isolated"; else mode="shared"; fi
    printf '%-14s %-10s %s\n' "$n" "$mode" "$(read_var "$(profile_file "$n")" ANTHROPIC_MODEL)"
  done <<EOF
$(profile_names)
EOF
  [ "$any" -eq 1 ] || c_dim "no profiles yet — try: ccp add deepseek deepseek/deepseek-v4-flash"
}

cmd_show() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: ccp show <name>"
  local f; f=$(need_profile "$name")

  c_dim "--- $f ---"
  cat "$f"
  c_dim "--- resolved environment ---"
  ( set +u; set -a; . "$f" >/dev/null 2>&1; set +a
    local k v
    for k in ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
             ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
             ANTHROPIC_CUSTOM_MODEL_OPTION_NAME CLAUDE_CODE_AUTO_COMPACT_WINDOW \
             CLAUDE_CODE_MAX_CONTEXT_TOKENS API_TIMEOUT_MS; do
      eval "v=\${$k:-}"
      [ -n "$v" ] && printf '%-36s %s\n' "$k" "$v"
    done
    printf '%-36s %s\n' "ANTHROPIC_AUTH_TOKEN" "$(mask "${ANTHROPIC_AUTH_TOKEN:-}")"
    printf '%-36s %s\n' "CLAUDE_CONFIG_DIR" "$(storage_root "$name")"
  )
}

# ------------------------------------------------------------------ test

cmd_test() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: ccp test <name>"
  local f; f=$(need_profile "$name")
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

# ---------------------------------------------------------------- backup

cmd_backup() {
  ensure_dir
  mkdir -p "$BACKUP_DIR"
  local out d n=0
  out="$BACKUP_DIR/ccp-$(date -u '+%Y%m%dT%H%M%SZ').tgz"
  local items=()
  [ -d "$SHARED_ROOT" ] && { items+=(".claude"); n=$((n+1)); }
  for d in "$HOME"/.claude-*; do
    [ -d "$d" ] || continue
    items+=("$(basename "$d")")
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || die "nothing to back up"

  # Caches and snapshots regenerate; leaving them out keeps this quick.
  tar czf "$out" -C "$HOME" \
    --exclude='*/cache' --exclude='*/image-cache' \
    --exclude='*/shell-snapshots' --exclude='*/downloads' \
    "${items[@]}"
  c_grn "backed up $n config dir(s) → $out"
  c_dim "  $(du -h "$out" | cut -f1) — caches and shell snapshots excluded"
}

# -------------------------------------------------------------- sessions

cmd_sessions() {
  local name="" all=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1; shift ;;
      -*) die "unknown option: $1" ;;
      *) name="$1"; shift ;;
    esac
  done

  local roots="" n
  if [ -n "$name" ]; then
    need_profile "$name" >/dev/null
    roots=$(storage_root "$name")
  else
    if [ -d "$SHARED_ROOT/projects" ]; then roots="$SHARED_ROOT"; fi
    while read -r n; do
      [ -n "$n" ] || continue
      if is_isolated "$n"; then
        roots="$roots
$(config_dir "$n")"
      fi
    done <<EOF
$(profile_names)
EOF
  fi

  local key; key=$(project_key "$PWD")
  if [ "$all" -eq 1 ]; then
    c_dim "all stored sessions"
  else
    c_dim "sessions for $PWD"
  fi

  local root label sid proj path size when any=0
  while read -r root; do
    [ -n "$root" ] || continue
    [ -d "$root/projects" ] || continue
    label=$(basename "$root")
    while IFS="$(printf '\t')" read -r sid proj path; do
      [ -n "$sid" ] || continue
      if [ "$all" -eq 0 ] && [ "$proj" != "$key" ]; then continue; fi
      any=1
      size=$(du -h "$path" 2>/dev/null | cut -f1)
      when=$(date -r "$path" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')
      if [ "$all" -eq 1 ]; then
        printf '%s  %6s  %s  %-16s %s\n' "$sid" "$size" "$when" "$label" "$proj"
      else
        printf '%s  %6s  %s  %s\n' "$sid" "$size" "$when" "$label"
      fi
    done <<EOF2
$(scan_sessions "$root")
EOF2
  done <<EOF3
$roots
EOF3

  if [ "$any" -eq 1 ]; then
    c_dim "resume with:  <profile> --resume <session-id>"
  else
    c_dim "no stored sessions found"
  fi
  return 0
}

# --------------------------------------------------------------- migrate

migrate_one() { # migrate_one <name> <dry> <keep>
  local name="$1" dry="$2" keep="$3"
  local src; src=$(config_dir "$name")

  if [ ! -d "$src/projects" ]; then
    c_dim "$name: nothing stored in $src — marking shared"
    [ "$dry" -eq 1 ] || { unset_var "$(profile_file "$name")" CCP_ISOLATED; }
    return 0
  fi

  c_grn "$name: $src/projects → $SHARED_ROOT/projects"

  local projdir pname dst f b copied skipped differ total_c=0 total_s=0
  for projdir in "$src"/projects/*/; do
    [ -d "$projdir" ] || continue
    pname=$(basename "$projdir")
    dst="$SHARED_ROOT/projects/$pname"
    copied=0; skipped=0; differ=0
    for f in "$projdir"*.jsonl; do
      [ -e "$f" ] || continue
      b=$(basename "$f")
      if [ -e "$dst/$b" ]; then
        skipped=$((skipped+1))
        cmp -s "$f" "$dst/$b" || { differ=$((differ+1)); }
      else
        copied=$((copied+1))
      fi
    done
    if [ "$dry" -eq 0 ]; then
      mkdir -p "$dst"
      cp_nc "$projdir." "$dst/"
    fi
    printf '  %-52s %2d copied  %2d present\n' "$pname" "$copied" "$skipped"
    [ "$differ" -eq 0 ] || warn "  $pname: $differ transcript(s) already exist with different content — destination kept"
    total_c=$((total_c+copied)); total_s=$((total_s+skipped))
  done

  if [ "$dry" -eq 1 ]; then
    c_dim "  (dry run — nothing written)"
    return 0
  fi

  if [ "$keep" -eq 1 ]; then
    c_dim "  --keep-isolated: '$name' still launches with CLAUDE_CONFIG_DIR=$src"
  else
    unset_var "$(profile_file "$name")" CCP_ISOLATED
    c_dim "  '$name' now shares $SHARED_ROOT"
  fi
  c_dim "  $src left intact — delete it yourself once you're satisfied"
  return 0
}

cmd_migrate() {
  local all=0 dry=0 keep=0 name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)            all=1; shift ;;
      --dry-run|-n)     dry=1; shift ;;
      --keep-isolated)  keep=1; shift ;;
      -*) die "unknown option: $1" ;;
      *) name="$1"; shift ;;
    esac
  done
  [ "$all" -eq 1 ] || [ -n "$name" ] || die "usage: ccp migrate <name>|--all [--dry-run] [--keep-isolated]"

  # which profiles have something to move
  local targets="" n
  if [ "$all" -eq 1 ]; then
    while read -r n; do
      [ -n "$n" ] || continue
      [ -d "$(config_dir "$n")/projects" ] && targets="$targets $n"
    done <<EOF
$(profile_names)
EOF
  else
    need_profile "$name" >/dev/null
    targets=" $name"
  fi
  [ -n "${targets# }" ] || { c_dim "no profile has its own session store — nothing to migrate"; return 0; }

  c_dim "profiles to migrate:${targets}"

  # Pre-flight: would the merged tree put one session ID under two projects?
  local listing; listing=$(mktemp)
  scan_sessions "$SHARED_ROOT" >> "$listing"
  for n in $targets; do scan_sessions "$(config_dir "$n")" >> "$listing"; done
  if ! check_cross_project "$listing"; then
    rm -f "$listing"
    die "aborting — resolve the duplicates above (a session ID under two projects makes --resume fail)"
  fi
  rm -f "$listing"
  c_grn "pre-flight: no cross-project session ID collisions"

  if [ "$dry" -eq 0 ]; then
    cmd_backup
  else
    c_dim "dry run — skipping backup"
  fi

  mkdir -p "$SHARED_ROOT/projects"
  for n in $targets; do migrate_one "$n" "$dry" "$keep"; done

  [ "$dry" -eq 1 ] || cmd_sync quiet
  c_grn "done"
  [ "$dry" -eq 1 ] || c_dim "note: $SHARED_ROOT may prompt you to trust each workspace once."
  [ "$dry" -eq 1 ] || c_dim "migrated sessions may not appear in the picker until opened — use: ccp sessions"
  [ "$dry" -eq 1 ] || post_sync_hint
}

# ------------------------------------------------------ isolate / share

cmd_isolate() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: ccp isolate <name>"
  local f; f=$(need_profile "$name")
  if is_isolated "$name"; then c_dim "'$name' is already isolated"; return 0; fi
  set_var "$f" CCP_ISOLATED "1"
  cmd_sync quiet
  c_grn "'$name' now uses $(config_dir "$name")"
  c_yel "sessions already in $SHARED_ROOT do not follow — copy one with: ccp resume <other> $name <id>"
  post_sync_hint
}

cmd_share() {
  local name="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) die "unknown option: $1" ;;
      *) name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: ccp share <name> [--force]"
  local f; f=$(need_profile "$name")
  if ! is_isolated "$name"; then c_dim "'$name' already shares $SHARED_ROOT"; return 0; fi

  local dir count
  dir=$(config_dir "$name")
  count=$(find "$dir/projects" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${count:-0}" -gt 0 ] && [ "$force" -eq 0 ]; then
    die "'$name' has $count stored session(s) in $dir that would be orphaned — run 'ccp migrate $name' first, or pass --force"
  fi

  unset_var "$f" CCP_ISOLATED
  cmd_sync quiet
  c_grn "'$name' now shares $SHARED_ROOT"
  post_sync_hint
}

# ---------------------------------------------------------------- resume

cmd_resume() {
  local from="${1:-}" to="${2:-}" sid="${3:-}"
  [ -n "$from" ] && [ -n "$to" ] || die "usage: ccp resume <from> <to> [session-id]"
  need_profile "$from" >/dev/null
  need_profile "$to"   >/dev/null

  local sroot droot key src dst file
  sroot=$(storage_root "$from")
  droot=$(storage_root "$to")
  key=$(project_key "$PWD")

  if [ "$sroot" = "$droot" ]; then
    c_grn "'$from' and '$to' already share $sroot — no copy needed"
    c_dim "just run:  $to --resume <session-id>    (see: ccp sessions)"
    return 0
  fi

  src="$sroot/projects/$key"
  dst="$droot/projects/$key"
  [ -d "$src" ] || die "'$from' has no sessions for $PWD"

  if [ -n "$sid" ]; then
    file="$src/$sid.jsonl"
    [ -e "$file" ] || die "no transcript $sid.jsonl in $src"
  else
    file=$(ls -t "$src"/*.jsonl 2>/dev/null | head -1)
    [ -n "$file" ] || die "no transcripts in $src"
    sid=$(basename "$file" .jsonl)
    c_dim "newest session in this directory: $sid"
  fi

  # don't land the same ID under a second project in the destination store
  local listing; listing=$(mktemp)
  scan_sessions "$droot" >> "$listing"
  printf '%s\t%s\t%s\n' "$sid" "$key" "$file" >> "$listing"
  if ! check_cross_project "$listing"; then
    rm -f "$listing"; die "aborting — that ID already exists under a different project in $droot"
  fi
  rm -f "$listing"

  mkdir -p "$dst"
  if [ -e "$dst/$sid.jsonl" ]; then
    c_yel "$sid.jsonl already present in $dst — not overwriting"
  else
    cp -a "$file" "$dst/"
    [ -d "$src/$sid" ] && cp_nc "$src/$sid" "$dst/"
    c_grn "copied $sid → $to"
  fi

  c_dim "now run (from $PWD):"
  printf '  %s --resume %s\n' "$to" "$sid"
  c_yel "cross-provider caveat: a transcript carrying another model's signed reasoning"
  c_yel "may be rejected on the first turn. Test before relying on it mid-task."
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
  # Profiles share ~/.claude unless the profile sets CCP_ISOLATED, so sessions
  # started under one provider are resumable under another with no copying.
  ( set -a; . "$f"; set +a
    if [ -n "${CCP_ISOLATED:-}" ]; then
      unset CCP_ISOLATED
      CLAUDE_CONFIG_DIR="$HOME/.claude-$name" command claude "$@"
    else
      unset CCP_ISOLATED
      command claude "$@"
    fi )
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
    subcmds=(init add set context rm ls show test key cost models sessions \
             migrate isolate share resume backup sync doctor help)
    if (( CURRENT == 2 )); then
      compadd -- $subcmds
      return
    fi
    profiles=(${${(f)"$(print -l ${CC_PROFILE_DIR:-$HOME/.config/cc-profiles}/*.env(N:t:r))"}:#_*})
    case ${words[2]} in
      set|context|ctx|rm|remove|del|delete|show|cat|test|migrate|isolate|share|sessions)
        (( CURRENT == 3 )) && compadd -- $profiles
        ;;
      resume)
        (( CURRENT == 3 || CURRENT == 4 )) && compadd -- $profiles
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
  chk "python3 installed"             "command -v python3"
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

  echo "storage:"
  local n count
  while read -r n; do
    [ -n "$n" ] || continue
    if ! grep -q '^CLAUDE_CODE_AUTO_COMPACT_WINDOW=' "$(profile_file "$n")" 2>/dev/null; then
      c_yel "  warn  $n has no declared context window (Claude Code will assume 200k)"
    fi
    if ! is_isolated "$n" && [ -d "$(config_dir "$n")/projects" ]; then
      # only complain about transcripts that were never copied across
      count=$(comm -23 \
        <(scan_sessions "$(config_dir "$n")" | cut -f1 | sort -u) \
        <(scan_sessions "$SHARED_ROOT"      | cut -f1 | sort -u) | wc -l | tr -d ' ')
      if [ "${count:-0}" -gt 0 ]; then
        c_yel "  warn  $n is shared but $count session(s) never migrated from $(config_dir "$n") — run: ccp migrate $n"
      fi
    fi
    : 
  done <<EOF
$(profile_names)
EOF

  # config dirs with no matching profile
  local d b
  for d in "$HOME"/.claude-*; do
    [ -d "$d" ] || continue
    b=$(basename "$d"); b=${b#.claude-}
    [ -e "$(profile_file "$b")" ] || c_yel "  warn  $d has no matching profile (leftover from 'ccp rm'?)"
  done

  # a session ID under two projects breaks --resume
  local listing; listing=$(mktemp)
  scan_sessions "$SHARED_ROOT" >> "$listing"
  while read -r n; do
    [ -n "$n" ] || continue
    is_isolated "$n" && scan_sessions "$(config_dir "$n")" >> "$listing"
  done <<EOF
$(profile_names)
EOF
  if check_cross_project "$listing" 2>/dev/null; then
    c_grn "  ok    no duplicate session IDs across projects"
  else
    c_yel "  warn  duplicate session IDs found — 'ccp migrate --dry-run --all' lists them"
    ok=1
  fi
  rm -f "$listing"

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
  cost)    shift; cmd_cost "$@" ;;
  models)  shift; cmd_models "$@" ;;
  sessions) shift; cmd_sessions "$@" ;;
  migrate) shift; cmd_migrate "$@" ;;
  isolate) shift; cmd_isolate "$@" ;;
  share)   shift; cmd_share "$@" ;;
  resume)  shift; cmd_resume "$@" ;;
  backup)  shift; cmd_backup "$@" ;;
  sync)    shift; cmd_sync "$@" ;;
  doctor)  shift; cmd_doctor "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command '$1' — try: ccp --help" ;;
esac
