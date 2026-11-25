#!/bin/sh
# status.sh: one-screen health check of the compose stack. Read-only.
#
#   scripts/status.sh              table of every container
#   scripts/status.sh -q           only the problems; prints nothing when healthy (for cron)
#   scripts/status.sh -w SECONDS   first wait (up to SECONDS) for containers still starting
#
# Exit status: 0 all ok | 1 something is down or unhealthy | 2 nothing is down but some
# containers are still starting | 3 could not check (bad usage, no Docker, unreadable output).
#
# Counts as ok: healthy containers, running containers that have no healthcheck, and
# one-shot containers that exited 0 (restart: "no", e.g. homeassistant-init, news-migrate).
# Ignored: leftovers from `docker compose run`. Uses `docker compose ps -a -q` plus
# `docker inspect`, so it needs neither jq nor a particular Compose version.

set -eu

fail() { echo "status: $*" >&2; exit 3; }

usage() {
  cat <<'EOF'
Usage: status.sh [-q|--quiet] [-w|--wait SECONDS]

Health table for every container of this compose project.
  -q, --quiet        print only problems; nothing at all when everything is healthy
  -w, --wait SECS    wait up to SECS for containers that are still starting; stops
                     early on the first hard failure

Exit: 0 ok | 1 down or unhealthy | 2 only "starting" left | 3 could not check
EOF
}

quiet=0
wait=0
while [ $# -gt 0 ]; do
  case $1 in
    -q|--quiet) quiet=1 ;;
    -w|--wait)
      [ $# -ge 2 ] || fail "$1 needs a number of seconds"
      case $2 in ''|*[!0-9]*) fail "$1 needs a number of seconds, got '$2'" ;; esac
      wait=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 3 ;;
  esac
  shift
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
command -v docker >/dev/null 2>&1 || fail "docker not found"

# One line per container: service|state|health|exit code|restart policy|restarts|name|one-off
FMT='{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}|{{.State.ExitCode}}|{{.HostConfig.RestartPolicy.Name}}|{{.RestartCount}}|{{.Name}}|{{index .Config.Labels "com.docker.compose.oneoff"}}'

# Services the compose files define (to spot ones with no container). Empty if unreadable.
WANT=$(docker compose config --services 2>/dev/null | LC_ALL=C sort || true)

# Sets ROWS (one inspect line per container). Any doubt about the output is "could not check".
snapshot() {
  ids=$(docker compose ps -a -q) || fail "docker compose ps failed (daemon not running, or a broken compose file / .env?)"
  ROWS=
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086  # word splitting of the ids is intended
    ROWS=$(docker inspect --format "$FMT" $ids) || fail "docker inspect failed"
    n_ids=$(printf '%s\n' "$ids" | grep -c . || true)
    n_rows=$(printf '%s\n' "$ROWS" | grep -c . || true)
    [ "$n_ids" -eq "$n_rows" ] || fail "docker inspect gave $n_rows rows for $n_ids containers"
  fi
}

# render MODE: "table", "quiet" (problems only) or "pending" (names still starting).
# Exit status of render: 0 ok | 1 problem | 2 only starting | 3 unreadable input.
render() {
  {
    if [ -n "$WANT" ]; then printf '%s\n' "$WANT" | sed 's/^/W|/'; fi
    if [ -n "$ROWS" ]; then printf '%s\n' "$ROWS" | LC_ALL=C sort -t'|' -k1,1 | sed 's/^/C|/'; fi
  } | awk -v mode="$1" '
function pad(s, n) { while (length(s) < n) s = s " "; return s }
function row(a, b, c, d,    s) {
  s = pad(a, width) "  " pad(b, 10) "  " pad(c, 10) "  " d
  sub(/ +$/, "", s)
  return s
}
BEGIN { FS = "|" }
$1 == "W" { if ($2 != "") { want[$2] = 1; worder[++nw] = $2 } next }
$1 == "C" {
  if (NF != 9 || $3 == "") { malformed++; next }
  if ($9 == "True") next                    # leftover from "docker compose run"
  svc = $2
  if (svc == "") { svc = $8; sub(/^\//, "", svc) }
  state = $3; health = $4; code = $5 + 0; policy = $6; restarts = $7 + 0
  seen[svc] = 1
  cls = "ok"; note = ""
  if (state == "running") {
    if (health == "starting") { cls = "wait"; note = "health check starting" }
    else if (health == "unhealthy") { cls = "bad"; note = "health check failing" }
    else if (health != "healthy") note = "no health check"
    if (cls == "ok" && restarts > 0) { if (note != "") note = note "; "; note = note "restarted " restarts "x" }
  } else if (state == "exited") {
    if (code == 0 && (policy == "no" || policy == "")) note = "completed"
    else if (code == 0) { cls = "bad"; note = "stopped (exit 0)" }
    else { cls = "bad"; note = "exit code " code }
  } else if (state == "restarting") { cls = "bad"; note = "crash-looping (last exit " code ")" }
  else if (state == "created") { cls = "wait"; note = "not started yet" }
  else { cls = "bad"; note = state }
  if (nw > 0 && !(svc in want)) { if (note != "") note = note "; "; note = note "not in the compose files" }
  n++; rsvc[n] = svc; rstate[n] = state; rhealth[n] = health; rcls[n] = cls; rnote[n] = note
}
END {
  if (malformed > 0) { print "status: could not parse docker output (" malformed " bad rows)" > "/dev/stderr"; exit 3 }
  for (i = 1; i <= nw; i++) {
    if (!(worder[i] in seen)) {
      n++; rsvc[n] = worder[i]; rstate[n] = "missing"; rhealth[n] = "-"; rcls[n] = "bad"; rnote[n] = "no container"
    }
  }
  width = 7
  for (i = 1; i <= n; i++) if (length(rsvc[i]) > width) width = length(rsvc[i])
  if (mode == "table") print row("SERVICE", "STATE", "HEALTH", "NOTE")
  for (i = 1; i <= n; i++) {
    if (rcls[i] == "ok") nok++
    else if (rcls[i] == "wait") nwait++
    else nbad++
    if (mode == "table" || (mode == "quiet" && rcls[i] != "ok")) print row(rsvc[i], rstate[i], rhealth[i], rnote[i])
    if (mode == "pending" && rcls[i] == "wait") { if (pend != "") pend = pend ", "; pend = pend rsvc[i] }
  }
  if (mode == "pending") print pend
  if (mode == "table") {
    ok_n = nok + 0; wait_n = nwait + 0; bad_n = nbad + 0
    print ""
    if (bad_n == 0 && wait_n == 0) print "all " n " ok"
    else print ok_n " ok, " wait_n " starting, " bad_n " with problems"
  }
  code = 0
  if (nbad > 0) code = 1
  else if (nwait > 0) code = 2
  exit code
}
'
}

snapshot
if [ -z "$ROWS" ] && [ -z "$WANT" ]; then
  echo "status: no containers found, and the compose config could not be read" >&2
  exit 1
fi

if [ "$wait" -gt 0 ]; then
  deadline=$(( $(date +%s) + wait ))
  last=
  while :; do
    rc=0; pend=$(render pending) || rc=$?
    [ "$rc" -ne 3 ] || exit 3                       # unreadable: the awk already said why
    [ "$rc" -eq 2 ] || break                        # all ok (0) or a hard failure (1): stop waiting
    [ "$(date +%s)" -lt "$deadline" ] || break      # out of time
    if [ "$quiet" -eq 0 ] && [ "$pend" != "$last" ]; then echo "waiting for: $pend"; last=$pend; fi
    sleep 3
    snapshot
  done
fi

mode=table
if [ "$quiet" -eq 1 ]; then mode=quiet; fi
rc=0; out=$(render "$mode") || rc=$?
if [ -n "$out" ]; then printf '%s\n' "$out"; fi
exit "$rc"
