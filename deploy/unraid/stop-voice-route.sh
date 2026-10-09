#!/bin/sh
set -eu
file=/run/suixinghao-voice-route.pid
if test -s "$file"; then
 read pid started < "$file"
 owned() {
  test -r /proc/$pid/stat || return 1
  test "$(cut -d ' ' -f 22 /proc/$pid/stat)" = "$started" || return 1
  test "$(tr '\000' '\n' < /proc/$pid/cmdline | head -1)" = /tmp/suixinghao-voice/mavo-pcm-bridge.armv7
 }
 if owned; then
  kill -TERM "$pid"
  n=0
  while owned; do n=$((n+1)); test "$n" -lt 50; sleep .1; done
 fi
fi
printf '0\n' > /sys/class/android_usb/f_audio/audio_enable
if test -p /run/voc_svr; then
 printf 'T\nT\nB\n' > /run/voc_svr
fi
test "$(cat /sys/class/android_usb/f_audio/audio_enable)" = 0
# Leave APR/voice modules resident until a module reboot; never force-unload.
echo route-stopped
