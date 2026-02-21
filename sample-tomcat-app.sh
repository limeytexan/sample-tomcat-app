#!/usr/bin/env bash
set -euo pipefail

# Flox Tomcat launcher
#
# Assumptions / conventions:
# - FLOX_ENV is set and contains:
#     - java on $FLOX_ENV/bin/java (or at least in $FLOX_ENV/bin on PATH)
#     - a Tomcat distribution somewhere under $FLOX_ENV with bin/catalina.sh
# - Immutable webapps live under: $out/webapps
#   where $out is the *package output prefix* (this script is installed under $out too).
#   IMPORTANT: this value should be substituted at build time; do not derive it from $0.
#
# - This script creates a mutable CATALINA_BASE in a temp/state directory:
#     conf/, logs/, temp/, work/, webapps/
#   and symlinks webapps from $out/webapps into the mutable base.

# This MUST be substituted at build time to the store/output prefix that contains this script.
# Common Nix-style is to replace @out@ with the actual output path.
out='@out@'

usage() {
  cat <<'USAGE'
Usage:
  flox-tomcat [--state-dir DIR] [--keep] {run|start|stop|restart|status}

Options:
  --state-dir DIR   Place mutable Tomcat instance dirs in DIR (created if needed).
                    If omitted, a fresh temp dir is created under $XDG_RUNTIME_DIR or /tmp.
  --keep            Do not delete the auto-created temp dir on exit (only applies when
                    --state-dir is not provided).

Commands:
  run       Run Tomcat in the foreground (exec)
  start     Start Tomcat in the background
  stop      Stop Tomcat
  restart   Stop then start
  status    Print key paths and whether a PID appears to be running
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

need() {
  local p="$1"
  [[ -e "$p" ]] || die "missing: $p"
}

is_running_pidfile() {
  local pidfile="$1"
  [[ -f "$pidfile" ]] || return 1
  local pid
  pid="$(<"$pidfile")"
  [[ -n "${pid// }" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

abspath_dir() {
  local d="$1"
  (cd "$d" && pwd -P)
}

find_java() {
  local j="${FLOX_ENV}/bin/java"
  if [[ -x "$j" ]]; then
    echo "$j"
    return 0
  fi
  if command -v java >/dev/null 2>&1; then
    command -v java
    return 0
  fi
  return 1
}

find_catalina() {
  if [[ -n "${CATALINA_HOME:-}" && -x "${CATALINA_HOME}/bin/catalina.sh" ]]; then
    echo "${CATALINA_HOME}/bin/catalina.sh"
    return 0
  fi

  local candidates=(
    "${FLOX_ENV}/bin/catalina.sh"
    "${FLOX_ENV}/bin/catalina"
    "${FLOX_ENV}/share/tomcat"*/bin/catalina.sh
    "${FLOX_ENV}/share/apache-tomcat"*/bin/catalina.sh
    "${FLOX_ENV}/libexec/tomcat"*/bin/catalina.sh
    "${FLOX_ENV}/opt/tomcat"*/bin/catalina.sh
    "${FLOX_ENV}/tomcat"*/bin/catalina.sh
  )

  local c
  for c in "${candidates[@]}"; do
    [[ -x "$c" ]] || continue
    echo "$c"
    return 0
  done

  if command -v catalina.sh >/dev/null 2>&1; then
    command -v catalina.sh
    return 0
  fi

  return 1
}

# --- args ---
STATE_DIR=""
KEEP=0
CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir)
      shift
      [[ $# -gt 0 ]] || die "--state-dir requires a value"
      STATE_DIR="$1"
      shift
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    run|start|stop|restart|status)
      CMD="$1"
      shift
      ;;
    *)
      die "unknown argument: $1 (try --help)"
      ;;
  esac
done

[[ -n "${CMD}" ]] || { usage; exit 2; }

# --- env checks ---
[[ -n "${FLOX_ENV:-}" ]] || die "FLOX_ENV is not set"
need "$FLOX_ENV"

need "$out"
need "$out/webapps"

JAVA_BIN="$(find_java)" || die "could not find java (expected ${FLOX_ENV}/bin/java or java on PATH)"
[[ "$JAVA_BIN" == "${FLOX_ENV}/"* ]] || {
  echo "warning: java resolved to '$JAVA_BIN' (not under \$FLOX_ENV)" >&2
}

CATALINA_SH="$(find_catalina)" || die "could not find Tomcat catalina.sh under \$FLOX_ENV (or set CATALINA_HOME)"
CATALINA_SH="$(cd "$(dirname "$CATALINA_SH")" && pwd -P)/$(basename "$CATALINA_SH")"

CATALINA_HOME="$(abspath_dir "$(dirname "$CATALINA_SH")/..")"
need "${CATALINA_HOME}/conf"
need "${CATALINA_HOME}/bin"

# --- state dir ---
AUTO_STATE=0
if [[ -z "$STATE_DIR" ]]; then
  AUTO_STATE=1
  base="${XDG_RUNTIME_DIR:-/tmp}"
  STATE_DIR="$(mktemp -d "${base%/}/flox-tomcat.XXXXXX")"
fi

mkdir -p "$STATE_DIR"

cleanup() {
  if [[ "$AUTO_STATE" -eq 1 && "$KEEP" -eq 0 ]]; then
    rm -rf "$STATE_DIR"
  fi
}
trap cleanup EXIT

CATALINA_BASE="$(abspath_dir "$STATE_DIR")/catalina-base"
mkdir -p "$CATALINA_BASE"/{conf,logs,temp,work,webapps}

# Copy default conf if not already present
if [[ ! -f "$CATALINA_BASE/conf/server.xml" ]]; then
  cp -a "${CATALINA_HOME}/conf/." "$CATALINA_BASE/conf/"
fi

# Populate webapps by symlinking from $out/webapps
if [[ -d "${out}/webapps" ]]; then
  shopt -s nullglob dotglob
  for app in "${out}/webapps/"*; do
    name="$(basename "$app")"
    [[ -e "$CATALINA_BASE/webapps/$name" ]] && continue
    ln -s "$app" "$CATALINA_BASE/webapps/$name" 2>/dev/null || {
      cp -a "$app" "$CATALINA_BASE/webapps/$name"
    }
  done
  shopt -u nullglob dotglob
else
  echo "warning: no webapps directory found at ${out}/webapps" >&2
fi

# --- environment for Tomcat ---
export CATALINA_HOME
export CATALINA_BASE
export CATALINA_TMPDIR="${CATALINA_BASE}/temp"
export CATALINA_PID="${CATALINA_BASE}/temp/tomcat.pid"
export CATALINA_OUT="${CATALINA_BASE}/logs/catalina.out"

# Help catalina.sh find Java.
JAVA_REAL="$JAVA_BIN"
if command -v readlink >/dev/null 2>&1; then
  if JAVA_REAL2="$(readlink "$JAVA_BIN" 2>/dev/null)"; then
    case "$JAVA_REAL2" in
      /*) JAVA_REAL="$JAVA_REAL2" ;;
      *)  JAVA_REAL="$(cd "$(dirname "$JAVA_BIN")" && pwd -P)/$JAVA_REAL2" ;;
    esac
  fi
fi
JAVA_HOME_GUESS="$(abspath_dir "$(dirname "$JAVA_REAL")/..")"
if [[ -x "${JAVA_HOME_GUESS}/bin/java" ]]; then
  export JAVA_HOME="$JAVA_HOME_GUESS"
else
  export JRE_HOME="$(abspath_dir "$(dirname "$JAVA_BIN")/..")"
fi

# --- command dispatch ---
case "$CMD" in
  status)
    echo "FLOX_ENV       = $FLOX_ENV"
    echo "out            = $out"
    echo "JAVA_BIN       = $JAVA_BIN"
    echo "CATALINA_HOME  = $CATALINA_HOME"
    echo "CATALINA_BASE  = $CATALINA_BASE"
    echo "LOGS           = $CATALINA_BASE/logs"
    echo "WEBAPPS (imm)  = $out/webapps"
    echo "WEBAPPS (mut)  = $CATALINA_BASE/webapps"
    if is_running_pidfile "$CATALINA_PID"; then
      echo "STATUS         = running (pid $(<"$CATALINA_PID"))"
      exit 0
    else
      echo "STATUS         = not running"
      exit 1
    fi
    ;;
  run)
    exec "$CATALINA_SH" run
    ;;
  start)
    "$CATALINA_SH" start
    echo "Tomcat started."
    echo "Logs: $CATALINA_BASE/logs"
    ;;
  stop)
    "$CATALINA_SH" stop
    echo "Tomcat stopped."
    ;;
  restart)
    "$CATALINA_SH" stop || true
    "$CATALINA_SH" start
    echo "Tomcat restarted."
    echo "Logs: $CATALINA_BASE/logs"
    ;;
esac
