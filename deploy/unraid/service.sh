#!/bin/bash
# Linux/Unraid supervisor. No device configuration is performed here.
set -eu
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
envfile=${VOICE_WEB_ENV_FILE:-${VOICE_WEB_DATA_DIR:-/mnt/user/appdata/suixinghao}/service.env}
if test -f "$envfile"; then
 set -a
 . "$envfile"
 set +a
fi
export VOICE_WEB_ENV_FILE="$envfile"
base=${VOICE_WEB_DATA_DIR:-/mnt/user/appdata/suixinghao}
binary=${VOICE_WEB_BINARY:-$base/voice-web}
pidfile=/var/run/suixinghao-supervisor.pid
owned() {
 test -s "$pidfile" || return 1
 read -r pid started < "$pidfile"
 case "$pid" in ''|*[!0-9]*) return 1;; esac
 test -r "/proc/$pid/stat" || return 1
 test "$(cut -d ' ' -f 22 "/proc/$pid/stat")" = "$started" || return 1
 tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fx -- "$self" >/dev/null
}
case "${1:-}" in
 run)
  umask 077
  mkdir -p "$base"
  chmod 0700 "$base"
  exec 9>/var/run/suixinghao-supervisor.lock
  flock -n 9 || exit 0
  printf '%s %s\n' "$$" "$(cut -d ' ' -f 22 /proc/$$/stat)" > "$pidfile"
  child=;running=1
  trap 'running=0; test -z "$child" || kill -TERM "$child" 2>/dev/null || true' TERM INT
  trap 'rm -f "$pidfile" "$base/service.pid"' EXIT
  while test "$running" = 1; do
   if test ! -x "$binary"; then sleep 5;continue;fi
   # Rotation occurs between runs; this is not a live file-size cap.
   if test -f "$base/service.log" && test "$(stat -c %s "$base/service.log")" -gt 5242880; then mv "$base/service.log" "$base/service.log.1";fi
   "$binary" >> "$base/service.log" 2>&1 & child=$!
   printf '%s\n' "$child" > "$base/service.pid"
   wait "$child" || true
   if test "$running" = 0; then wait "$child" 2>/dev/null || true;break;fi
   child=;sleep 5
  done
  ;;
 start)
  umask 077
  mkdir -p "$base"
  chmod 0700 "$base"
  test -f "$envfile" || { echo 'Missing service.env; configure the example first' >&2;exit 1; }
  test -x "$binary" || { echo 'Service binary missing or not executable' >&2;exit 1; }
  if owned; then echo 'Already running';exit 0;fi
  nohup /bin/bash "$self" run </dev/null >/dev/null 2>&1 &
  ;;
 stop)
  if owned; then
   kill -TERM "$pid"
   for n in {1..90};do owned || exit 0;sleep 1;done
   echo 'Graceful stop still pending; check before updating' >&2;exit 1
  fi
  ;;
 status)
  if owned; then echo 'running';else echo 'stopped';exit 1;fi
  ;;
 *) echo 'Usage: service.sh start|stop|status|run' >&2;exit 2;;
esac
