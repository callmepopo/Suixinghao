#!/bin/bash
# Only load the verified temporary runtime on an already authorized target.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
base=${VOICE_WEB_DATA_DIR:-/mnt/user/appdata/suixinghao}
adb=${VOICE_WEB_ADB:-/usr/bin/adb}
assets=${VOICE_WEB_MODULE_ASSETS:-$base/drivers/module-voice}
serial=${VOICE_WEB_ADB_SERIAL:-}
usb=${VOICE_WEB_MODULE_USB_DEVICE:-}
case "${1:-}" in start|stop) ;; *) echo 'Usage: module-route.sh start|stop' >&2;exit 2;; esac
test -n "$serial" || { echo 'Set VOICE_WEB_ADB_SERIAL for the authorized target' >&2;exit 1; }
case "$usb" in /sys/bus/usb/devices/*) ;; *) echo 'Set the target USB sysfs device path' >&2;exit 1;; esac
case "${usb#/sys/bus/usb/devices/}" in ''|*/*|*..*) exit 1;; esac
test "$(cat "$usb/product")" = Baiwang
test "$("$adb" -s "$serial" get-devpath | tr -d '\r')" = "usb:${usb##*/}" || { echo 'ADB target does not match USB path' >&2;exit 1; }
test "$("$adb" -s "$serial" shell uname -r | tr -d '\r')" = 3.18.44
test "$("$adb" -s "$serial" shell id -u | tr -d '\r')" = 0
case "$1" in
 stop)
  "$adb" -s "$serial" shell 'if test -f /tmp/suixinghao-voice/stop-route.sh; then sh /tmp/suixinghao-voice/stop-route.sh; else test ! -e /sys/class/android_usb/f_audio/audio_enable || echo 0 > /sys/class/android_usb/f_audio/audio_enable; fi' >/dev/null
  ;;
 start)
  (cd "$assets" && sha256sum -c "$scripts/module-voice.SHA256SUMS" >/dev/null)
  "$adb" -s "$serial" shell 'mkdir -p /tmp/suixinghao-voice' >/dev/null
  for file in qdc507_aprv3.ko qdc507_voice.ko mavo-pcm-bridge.armv7; do "$adb" -s "$serial" push "$assets/$file" "/tmp/suixinghao-voice/$file" >/dev/null 2>&1;done
  "$adb" -s "$serial" push "$scripts/start-voice-route.sh" /tmp/suixinghao-voice/start-route.sh >/dev/null 2>&1
  "$adb" -s "$serial" push "$scripts/stop-voice-route.sh" /tmp/suixinghao-voice/stop-route.sh >/dev/null 2>&1
  "$adb" -s "$serial" shell 'set -e; chmod 700 /tmp/suixinghao-voice/mavo-pcm-bridge.armv7; grep -q "^qdc507_aprv3 " /proc/modules || insmod /tmp/suixinghao-voice/qdc507_aprv3.ko; grep -q "^qdc507_voice " /proc/modules || insmod /tmp/suixinghao-voice/qdc507_voice.ko; n=0; while test ! -c /dev/snd/pcmC0D4c; do n=$((n+1)); test "$n" -lt 30 || exit 1;sleep .1;done;sh /tmp/suixinghao-voice/start-route.sh' >/dev/null
  for n in {1..30};do
   if "$adb" -s "$serial" shell 'test "$(cat /sys/class/android_usb/f_audio/audio_enable)" = 1 && grep -q "state: RUNNING" /proc/asound/card0/pcm4c/sub0/status && grep -q "state: RUNNING" /proc/asound/card0/pcm4p/sub0/status' >/dev/null 2>&1;then exit 0;fi
   sleep .1
  done
  exit 1
  ;;
esac
