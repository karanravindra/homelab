#!/bin/sh
# lint-env.sh: check that .env.example and the compose files agree on variables.
#
#   scripts/lint-env.sh [DIR]   DIR = a checkout with compose.yml, services/*.yml and
#                               .env.example (default: this repo). Exit 1 on problems.
#
# Needs no Docker, so it runs anywhere. As a pre-commit hook (from the repo root):
#   printf '#!/bin/sh\nexec scripts/lint-env.sh\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
#
# Checks:
#   - every ${VAR} a compose file uses is in .env.example (set or commented out)
#   - a var used without a default is *set* there, not only commented out
#   - every key in .env.example is used by some compose file (COMPOSE_* are read by
#     Compose itself, so they are exempt)
# Handled: $$VAR escapes, nested ${A:-${B}}, bare $VAR, and YAML comment lines.

set -eu

die() { echo "lint-env: $*" >&2; exit 2; }

case ${1:-} in
  -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -?*) die "unknown option: $1 (try --help)" ;;
esac

ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$ROOT" 2>/dev/null || die "no such directory: $ROOT"
[ -f .env.example ] || die ".env.example not found in $ROOT"
[ -f compose.yml ] || die "compose.yml not found in $ROOT"

files=compose.yml
for f in services/*.yml; do
  if [ -f "$f" ]; then files="$files $f"; fi
done

# shellcheck disable=SC2086  # $files is a list of plain file names
exec awk -v exname=.env.example '
# Same key rules as env-sync.sh: "A" = active KEY=..., "C" = commented "# KEY=...".
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

# ---- .env.example: which keys are documented, and how ----
FILENAME == exname {
  classify($0)
  if (pkind == "") next
  if (!(pkey in seen)) { seen[pkey] = 1; order[++nex] = pkey }
  if (pkind == "A") act[pkey] = 1
  else cmt[pkey] = 1
  next
}

# ---- compose files: which variables are used, and whether each has a default ----
{
  line = $0
  if (line ~ /^[ \t]*#/) next                  # YAML comment line
  sub(/[ \t]+#.*$/, "", line)                  # trailing YAML comment
  # Scan only the "$NAME" / "${NAME" head so a nested ${A:-${B}} yields both names.
  while (match(line, /\$(\$|\{[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*)/)) {
    tok = substr(line, RSTART, RLENGTH)
    line = substr(line, RSTART + RLENGTH)
    if (tok == "$$") continue                  # escaped dollar, not a reference
    optional = 0
    if (substr(tok, 2, 1) == "{") {
      name = substr(tok, 3)
      one = substr(line, 1, 1); two = substr(line, 1, 2)
      if (two == ":-" || two == ":+" || one == "-" || one == "+") optional = 1
    } else {
      name = substr(tok, 2)
    }
    if (!(name in used)) { used[name] = 1; uorder[++nused] = name; where[name] = FILENAME ":" FNR }
    if (!optional) need[name] = 1
  }
}

END {
  for (i = 1; i <= nused; i++) {
    k = uorder[i]
    if (!(k in act) && !(k in cmt)) miss[++nmiss] = k "  (" where[k] ")"
    else if ((k in need) && !(k in act)) onlycmt[++nonly] = k
  }
  for (i = 1; i <= nex; i++) {
    k = order[i]
    if (!(k in used) && k !~ /^COMPOSE_/) unused[++nun] = k
  }
  if (nmiss + nonly + nun == 0) {
    print "lint-env: ok (" nused " variables used by the compose files, all in .env.example)"
    exit 0
  }
  print "lint-env: .env.example and the compose files disagree"
  if (nmiss > 0) {
    print "  used by compose but missing from .env.example:"
    for (i = 1; i <= nmiss; i++) print "    " miss[i]
  }
  if (nonly > 0) {
    print "  no default in compose, but only commented out in .env.example:"
    for (i = 1; i <= nonly; i++) print "    " onlycmt[i]
  }
  if (nun > 0) {
    print "  in .env.example but not used by any compose file:"
    for (i = 1; i <= nun; i++) print "    " unused[i]
  }
  exit 1
}
' .env.example $files
