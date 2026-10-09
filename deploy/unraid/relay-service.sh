#!/bin/bash
# Independent publisher relay supervisor; no modem, AT, ADB or audio operations.
set -eu
: "${SXH_RELAY_DIR:?Set private relay data directory}"
: "${SXH_RELAY_BIN:?Set exact relay binary absolute path}"
: "${SXH_RELAY_ENV:?Set private relay environment file absolute path}"
case "$SXH_RELAY_DIR:$SXH_RELAY_BIN:$SXH_RELAY_ENV" in *$'\n'*) exit 2;; esac
[[ "$SXH_RELAY_DIR" = /* && "$SXH_RELAY_BIN" = /* && "$SXH_RELAY_ENV" = /* ]] || exit 2
umask 077
mkdir -p "$SXH_RELAY_DIR"
pidfile="$SXH_RELAY_DIR/supervisor.pid"
case "${1:-}" in
  run)
    exec 9>"$SXH_RELAY_DIR/supervisor.lock"
    flock -n 9 || exit 0
    printf '%s\n' "$$" >"$pidfile"
    child=;running=1
    trap 'running=0; test -z "$child" || kill -TERM "$child" 2>/dev/null || true' TERM INT
    trap 'rm -f "$pidfile"' EXIT
    set -a
    . "$SXH_RELAY_ENV"
    export VOICE_WEB_DATA_DIR="$SXH_RELAY_DIR"
    set +a
    while [[ "$running" = 1 ]]; do
      [[ -x "$SXH_RELAY_BIN" ]] || exit 1
      if [[ -f "$SXH_RELAY_DIR/service.log" ]] && [[ $(stat -c %s "$SXH_RELAY_DIR/service.log") -gt 5242880 ]]; then mv "$SXH_RELAY_DIR/service.log" "$SXH_RELAY_DIR/service.log.1"; fi
      "$SXH_RELAY_BIN" relay >>"$SXH_RELAY_DIR/service.log" 2>&1 & child=$!
      wait "$child" || true
      if [[ "$running" != 1 ]]; then wait "$child" 2>/dev/null || true;break;fi
      child=;sleep 5
    done
    ;;
  start)
    [[ -f "$SXH_RELAY_ENV" && -x "$SXH_RELAY_BIN" ]] || exit 1
    nohup bash "${BASH_SOURCE[0]}" run </dev/null >/dev/null 2>&1 &
    ;;
  stop)
    [[ -s "$pidfile" ]] || exit 0
    read -r pid <"$pidfile"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || exit 1
    [[ -r "/proc/$pid/cmdline" ]] || exit 0
    # Verify the exact supervisor script and mode, not a loose process match.
    mapfile -d '' -t argv <"/proc/$pid/cmdline"
    [[ "${argv[1]:-}" = "${BASH_SOURCE[0]}" && "${argv[2]:-}" = run ]] || exit 1
    kill -TERM "$pid"
    for ((attempt=0;attempt<30;attempt++)); do kill -0 "$pid" 2>/dev/null || exit 0;sleep 1;done
    printf '%s\n' 'Relay graceful stop pending; do not replace the binary.' >&2
    exit 1
    ;;
  *) printf '%s\n' 'Usage: relay-service.sh start|stop|run' >&2;exit 2;;
esac
