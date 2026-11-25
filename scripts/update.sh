#!/bin/sh
# update.sh: pull the repo, sync .env, check it, and (re)deploy the stack.
#
#   scripts/update.sh [--no-pull] [--no-wait] [SERVICE...]
#
# Steps; a failure in any of them stops the run before the next:
#   1. git pull --ff-only                  skip with --no-pull
#   2. scripts/env-sync.sh                 add keys that are new in .env.example to .env
#   3. stop while a key the template leaves empty is still blank in .env
#      (docker compose config -q does not catch blank values; ALLOW_BLANK below lists
#      the keys that may stay blank)
#   4. docker compose config -q            validate the compose files
#   5. docker compose pull, then up -d --remove-orphans     only SERVICE... if given
#   6. scripts/status.sh -w 180            wait for health; skip with --no-wait, and it is
#                                          skipped when SERVICE... is given
#
# --remove-orphans also removes containers of services you deleted from the compose files
# (bind-mounted data is untouched). Exit status after step 6: 1 unhealthy, 2 still starting.

set -eu

# Keys that may stay blank. BESZEL_KEY only exists once the hub is up (see .env.example).
ALLOW_BLANK=${ALLOW_BLANK-BESZEL_KEY}
WAIT_SECONDS=${WAIT_SECONDS:-180}

die() { echo "update: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: update.sh [--no-pull] [--no-wait] [SERVICE...]

Pull the repo, sync .env, validate, then docker compose pull + up -d --remove-orphans.
Stops if a required key is still blank in .env.
  --no-pull   do not run git pull
  --no-wait   do not wait for health at the end
  SERVICE...  only pull/start these services (no health wait)

Env: ALLOW_BLANK="KEY ..." keys allowed to stay blank (default BESZEL_KEY),
     WAIT_SECONDS=180 how long to wait for health.
EOF
}

# The whole body is a function that is called on the last line: the shell has parsed the
# entire script before step 1, so a git pull that rewrites this file cannot break the run.
main() {
  pull=1
  wait=1
  while [ $# -gt 0 ]; do
    case $1 in
      --no-pull) pull=0 ;;
      --no-wait) wait=0 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      -?*) echo "update: unknown option: $1" >&2; usage >&2; exit 2 ;;
      *) break ;;
    esac
    shift
  done

  ROOT=$(cd "$(dirname "$0")/.." && pwd)
  cd "$ROOT"
  command -v docker >/dev/null 2>&1 || die "docker not found"
  docker compose version >/dev/null 2>&1 || die "needs the Docker Compose v2 plugin (docker compose)"

  if [ "$pull" -eq 1 ]; then
    step "git pull --ff-only"
    if git rev-parse --git-dir >/dev/null 2>&1; then
      git pull --ff-only || die "git pull failed (local changes, or history that diverged?). Fix that, or rerun with --no-pull"
    else
      echo "not a git checkout, skipping"
    fi
  fi

  step "sync .env with .env.example"
  sh scripts/env-sync.sh

  step "check required values"
  blank=$(sh scripts/env-sync.sh --blank)
  fatal=
  allowed=
  for k in $blank; do
    case " $ALLOW_BLANK " in
      *" $k "*) allowed="$allowed $k" ;;
      *) fatal="$fatal $k" ;;
    esac
  done
  if [ -n "$allowed" ]; then echo "left blank on purpose (ALLOW_BLANK):$allowed"; fi
  if [ -n "$fatal" ]; then
    echo "update: these keys are still blank in .env. Fill them in, then run this again:" >&2
    for k in $fatal; do echo "  $k" >&2; done
    case $fatal in
      *PASSWORD*) echo "  (openssl rand -hex 24 makes a good, URL-safe password)" >&2 ;;
    esac
    exit 1
  fi
  echo "ok"

  step "docker compose config -q"
  docker compose config -q || die "the compose files do not validate (see above)"

  step "docker compose pull $*"
  docker compose pull "$@" || die "pull failed. A private image (ghcr.io/karanravindra/orbit-news) needs: docker login ghcr.io"

  step "docker compose up -d --remove-orphans $*"
  docker compose up -d --remove-orphans "$@"

  if [ "$wait" -eq 1 ] && [ $# -eq 0 ]; then
    step "waiting for health (up to ${WAIT_SECONDS}s)"
    rc=0
    sh scripts/status.sh -w "$WAIT_SECONDS" || rc=$?
    echo
    case $rc in
      0) echo "update: done" ;;
      1) echo "update: deployed, but something is down or unhealthy (see above)" >&2 ;;
      2) echo "update: deployed, but some containers are still starting; check with scripts/status.sh" >&2 ;;
      *) echo "update: deployed, but the health check could not run (exit $rc)" >&2 ;;
    esac
    exit "$rc"
  fi
  echo
  echo "update: done (check health with scripts/status.sh)"
}

main "$@"
