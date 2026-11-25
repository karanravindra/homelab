#!/bin/sh
# env-sync.sh: add keys that are new in .env.example to your existing .env.
#
#   scripts/env-sync.sh              merge <repo>/.env.example into <repo>/.env
#   scripts/env-sync.sh -n           dry run: show what would be added, change nothing
#   scripts/env-sync.sh --blank      only list the keys still blank in .env, one per line
#   scripts/env-sync.sh ENV EXAMPLE  use these files instead
#
# Without committing it first, run it on the box over SSH:
#   ssh box 'cd ~/homelab && sh -s -- .env .env.example' < scripts/env-sync.sh
#
# Append-only: values already in .env are never changed or removed, and the file's
# mode and owner are untouched (it is only ever appended to). Prints key names, never
# values. Plain POSIX sh + awk. Tested with dash/bash and macOS (BSD) awk; on a box with
# mawk or busybox awk, run with -n first and check the list of keys before applying.

set -eu

die() { echo "env-sync: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: env-sync.sh [-n|--dry-run|--blank] [ENV_FILE [EXAMPLE_FILE]]

Adds keys that are new in .env.example to your existing .env.
  - append-only: existing values are never changed or removed
  - commented-out optional overrides (# KEY=...) are carried over too
  - prints key names only, never values
  - -n, --dry-run: show what would be added, change nothing
  - --blank: change nothing; print only the keys the template leaves empty
    and .env leaves empty (or unset), one per line (for other scripts)

Defaults: <repo>/.env and <repo>/.env.example (repo = parent of this script's dir).
EOF
}

dry=0
blankonly=0
while [ $# -gt 0 ]; do
  case $1 in
    -n|--dry-run) dry=1 ;;
    --blank) dry=1; blankonly=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -?*) echo "env-sync: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done
[ $# -le 2 ] || { usage >&2; exit 2; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENV_FILE=${1:-$ROOT/.env}
EXAMPLE_FILE=${2:-$ROOT/.env.example}

[ -f "$EXAMPLE_FILE" ] || die "$EXAMPLE_FILE not found"

if [ -e "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || die "$ENV_FILE is not a regular file"
  if [ "$dry" -eq 0 ] && [ ! -w "$ENV_FILE" ]; then
    die "$ENV_FILE is not writable (try sudo)"
  fi
  SCAN=$ENV_FILE
else
  SCAN=/dev/null   # no .env yet: everything in the example counts as missing
fi

# The lines to append. Only ever contains text copied from .env.example.
BLOCK=$(mktemp "${TMPDIR:-/tmp}/env-sync.XXXXXX")
trap 'rm -f "$BLOCK"' EXIT
trap 'exit 1' INT TERM HUP

# awk reads .env first (what is already set), then .env.example (what should be).
# Block goes to the file named by "out"; the human-readable report goes to stdout.
REPORT=$(awk \
  -v out="$BLOCK" -v scan="$SCAN" -v dry="$dry" -v blankonly="$blankonly" \
  -v envname="$(basename "$ENV_FILE")" -v exname="$(basename "$EXAMPLE_FILE")" '
# Sets pkind ("A" active KEY=..., "C" commented "# KEY=...", "" anything else) and pkey.
# Deliberately liberal about what counts as present: leading spaces, "export KEY=",
# and spaces before "=" on active lines. A missed append is harmless and visible; a
# blank duplicate added under a real value would silently override it.
function classify(line,    s) {
  pkind = ""; pkey = ""
  s = line
  sub(/\r$/, "", s)
  sub(/^[ \t]+/, "", s)
  if (substr(s, 1, 1) == "#") {
    sub(/^#[ \t]*/, "", s)
    sub(/^export[ \t]+/, "", s)
    if (match(s, /^[A-Za-z_][A-Za-z0-9_.-]*=/)) { pkind = "C"; pkey = substr(s, 1, RLENGTH - 1) }
    return
  }
  sub(/^export[ \t]+/, "", s)
  if (match(s, /^[A-Za-z_][A-Za-z0-9_.-]*[ \t]*=/)) {
    pkind = "A"; pkey = substr(s, 1, RLENGTH - 1); sub(/[ \t]+$/, "", pkey)
  }
}

# Value after the first "=", minus an inline " # comment", whitespace and empty quotes.
function valueof(line,    v) {
  v = line
  sub(/\r$/, "", v)
  sub(/^[^=]*=/, "", v)
  sub(/[ \t]+#.*$/, "", v)
  sub(/^[ \t]+/, "", v)
  sub(/[ \t]+$/, "", v)
  if (v == "\"\"" || v == (sq sq)) v = ""
  return v
}

BEGIN { sq = "\047"; isdry = (dry == 1); first = 1; gap = 0 }

# ---- pass 1: .env ----
FILENAME == scan {
  classify($0)
  if (pkind == "A") {
    if (!(pkey in envact)) envorder[++nenvkeys] = pkey
    envact[pkey] = 1
    envval[pkey] = valueof($0)   # last assignment wins, same as dotenv
  } else if (pkind == "C") {
    envcmt[pkey] = 1
  }
  nenv++
  lastblank = ($0 ~ /^[ \t\r]*$/)
  next
}

# ---- pass 2: .env.example ----
{
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^[ \t]*$/) { nbuf = 0; gap = 1; next }   # blank line ends a comment block
  classify(line)
  if (pkind == "") { buf[++nbuf] = line; next }        # prose comment: hold for the next key

  k = pkey
  exk[k] = 1

  # The template wants a value here and .env has none (unset, empty, or only commented).
  if (pkind == "A" && valueof(line) == "" && !(k in blankseen) && (!(k in envact) || envval[k] == "")) {
    blankseen[k] = 1; blanks[++nblank] = k
  }

  # Already in .env (set or commented out) or already queued: skip it and its comments.
  if ((k in envact) || (k in envcmt) || (k in added)) { nbuf = 0; next }

  if (first) { if (nenv > 0 && !lastblank) print "" > out; first = 0 }
  else if (gap) print "" > out
  gap = 0
  for (i = 1; i <= nbuf; i++) print buf[i] > out
  nbuf = 0
  print line > out
  added[k] = pkind
  addorder[++nadd] = k
}

END {
  if (blankonly == 1) { for (i = 1; i <= nblank; i++) print blanks[i]; exit }
  for (i = 1; i <= nenvkeys; i++) { k = envorder[i]; if (!(k in exk)) stale[++nstale] = k }

  if (nadd == 0) {
    print envname " already has every key in " exname "."
  } else {
    verb = isdry ? "would add to " : "added to "
    print verb envname ":"
    for (i = 1; i <= nadd; i++) {
      k = addorder[i]
      tag = ""
      if (added[k] == "C") tag = "  (optional, commented out)"
      print "  + " k tag
    }
  }
  if (nblank > 0) {
    print ""
    print "blank in " envname " (fill in, unless intentionally empty):"
    for (i = 1; i <= nblank; i++) print "  " blanks[i]
  }
  if (nstale > 0) {
    print ""
    print "in " envname " but not in " exname " (left alone):"
    for (i = 1; i <= nstale; i++) print "  " stale[i]
  }
}
' "$SCAN" "$EXAMPLE_FILE")

if [ "$blankonly" -eq 1 ]; then
  if [ -n "$REPORT" ]; then printf '%s\n' "$REPORT"; fi
  exit 0
fi

if [ "$dry" -eq 0 ] && [ -s "$BLOCK" ]; then
  [ -e "$ENV_FILE" ] || (umask 077; : > "$ENV_FILE")        # new file: owner-only
  # If the last line has no trailing newline, terminate it so we do not glue onto it.
  if [ -s "$ENV_FILE" ] && [ -n "$(tail -c1 "$ENV_FILE")" ]; then printf '\n' >> "$ENV_FILE"; fi
  cat "$BLOCK" >> "$ENV_FILE"
fi

printf '%s\n' "$REPORT"

if [ "$dry" -eq 1 ] && [ -s "$BLOCK" ]; then
  [ -e "$ENV_FILE" ] || echo "($(basename "$ENV_FILE") does not exist yet; it would be created)"
  printf '\n%s\n' '--- would append ---'
  cat "$BLOCK"
  printf '%s\n' '--- end ---'
fi
