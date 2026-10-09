#!/bin/bash
# Add a serial-driver ID only for one inspected, explicitly selected device.
set -euo pipefail
expected=${HIDECK_UNRAID_KERNEL:-6.1.126-Unraid}
vendor=${HIDECK_USB_VENDOR:-2c7c}
product=${HIDECK_USB_PRODUCT:-0125}
usb=${HIDECK_USB_DEVICE:-}
[[ "$vendor" =~ ^[0-9a-fA-F]{4}$ && "$product" =~ ^[0-9a-fA-F]{4}$ ]] || exit 2
case "$usb" in /sys/bus/usb/devices/*) ;; *) echo 'Set HIDECK_USB_DEVICE after inspecting the target' >&2;exit 2;; esac
case "${usb#/sys/bus/usb/devices/}" in ''|*/*|*..*) exit 2;; esac
test "$(uname -r)" = "$expected" || { echo 'Kernel mismatch; do not load cached drivers' >&2;exit 1; }
test "$(cat "$usb/idVendor")" = "${vendor,,}"
test "$(cat "$usb/idProduct")" = "${product,,}"
count=0
for entry in /sys/bus/usb/devices/*;do
 if test -f "$entry/idVendor" && test "$(cat "$entry/idVendor")" = "${vendor,,}" && test "$(cat "$entry/idProduct")" = "${product,,}";then count=$((count+1));fi
done
test "$count" = 1 || { echo 'Multiple matching devices; do not bind globally' >&2;exit 1; }
modprobe option
printf '%s %s\n' "$vendor" "$product" > /sys/bus/usb-serial/drivers/option1/new_id
