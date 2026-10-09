#!/bin/sh
set -eu
# Run inside the QDC507 module after verified runtime loading.
test "$(uname -r)" = 3.18.44
test -c /dev/snd/pcmC0D4p
test -c /dev/snd/pcmC0D4c
test -x /tmp/suixinghao-voice/mavo-pcm-bridge.armv7
owned() {
 test -s "$1" || return 1
 read pid started < "$1"
 test "$(cut -d ' ' -f 22 /proc/$pid/stat 2>/dev/null)" = "$started" || return 1
 test "$(tr '\000' '\n' < /proc/$pid/cmdline | head -1)" = "$2"
}
cal=/run/suixinghao-voice-calibration.pid
log=/run/suixinghao-voice-calibration.log
if ! owned "$cal" /usr/bin/alsaucm_test; then
 test ! -p /run/alsaucm_test || { echo 'Unowned calibration FIFO; stop'; exit 1; }
 nohup /usr/bin/alsaucm_test </dev/null > "$log" 2>&1 &
 pid=$!
 printf '%s %s\n' "$pid" "$(cut -d ' ' -f 22 /proc/$pid/stat)" > "$cal"
 n=0
 while test ! -p /run/alsaucm_test; do
  kill -0 "$pid"; n=$((n+1)); test "$n" -lt 50; sleep .1
 done
fi
if ! grep -q 'ACDB -> Sent VocProc Cal!' "$log"; then
 printf 'open snd_soc_msm_9x07_Tomtom_I2S\n' > /run/alsaucm_test
 printf 'set _verb VoLTE\n' > /run/alsaucm_test
 printf 'set _enadev Auxpcm Rx\n' > /run/alsaucm_test
 printf 'set _enadev Auxpcm Tx\n' > /run/alsaucm_test
 n=0
 while ! grep -q 'ACDB -> Sent VocProc Cal!' "$log"; do
  n=$((n+1)); test "$n" -lt 100; sleep .1
 done
fi
echo calibration-ready
route=/run/suixinghao-voice-route.pid
if ! owned "$route" /tmp/suixinghao-voice/mavo-pcm-bridge.armv7; then
 nohup /tmp/suixinghao-voice/mavo-pcm-bridge.armv7 --voice-route-session --verbose </dev/null > /run/suixinghao-voice-route.log 2>&1 &
 pid=$!
 printf '%s %s\n' "$pid" "$(cut -d ' ' -f 22 /proc/$pid/stat)" > "$route"
fi
