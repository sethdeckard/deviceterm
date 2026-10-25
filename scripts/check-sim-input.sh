#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Check touch delivery to a simulator pane while dtuhidd, the simulator's HID
# daemon, is marked active. That state disconnects the services
# SimulatorKit's Indigo port feeds.
#
# Run inside a DeviceTerm tab, against a simulator pane:
#
#   scripts/check-sim-input.sh <pane>
#
# Taps normalized point (0.5, 0.02) and checks for a guest contact log. The
# tap may change the current UI. Any contact during the check counts, so
# other input to the sim at the same time can produce a false pass. The flag
# is put back the way it was found, because leaving it set can strand
# another tool on the Indigo port (idb, for one).

set -u
setopt pipefail

pane=${1:?usage: check-sim-input.sh <pane>}
flag=com.apple.coredevice.dtuhidd.active

# Accepts the short id or the full one; the log names a pane by its short id.
read -r udid short <<<"$(deviceterm pane list --json | /usr/bin/python3 -I -c '
import json, sys
want = sys.argv[1].lower()
for pane in json.load(sys.stdin):
    ids = (str(pane.get("shortId", "")).lower(), str(pane.get("id", "")).lower())
    if want in ids and pane.get("simulator"):
        print(pane["simulator"]["udid"], pane["shortId"])
' "$pane")" || exit 1
if [[ -z ${udid:-} ]]; then
    print -u2 "no simulator pane $pane in this tab"
    exit 1
fi

transport=$(/usr/bin/log show --last 1d --style compact \
    --predicate "subsystem == \"com.deviceterm.daemon\" && eventMessage CONTAINS \"pane published: shortId=$short\"" \
    2>/dev/null | grep -o 'input=.*' | tail -1)
print "pane $short  udid $udid  ${transport:-input=unknown (no publish line in the last day)}"

flag_value() { xcrun simctl spawn "$udid" notifyutil -g "$flag" | awk '{print $2}' }
set_flag() {
    xcrun simctl spawn "$udid" notifyutil -s "$flag" "$1" >/dev/null &&
        xcrun simctl spawn "$udid" notifyutil -p "$flag" >/dev/null &&
        [[ $(flag_value) == "$1" ]]
}

previous=$(flag_value) || { print -u2 "couldn't read $flag in the simulator"; exit 1; }
restore() {
    set_flag "${previous:-0}" || print -u2 "warning: couldn't restore $flag to ${previous:-0}"
}
trap restore EXIT

print "forcing $flag=1 (dtuhidd active)"
set_flag 1 || { print -u2 "couldn't set $flag; the check would prove nothing"; exit 1; }

contacts=$(mktemp -t check-sim-input)
xcrun simctl spawn "$udid" log stream --style compact --level debug \
    --predicate 'process == "backboardd" && eventMessage CONTAINS "new contact"' >"$contacts" 2>/dev/null &
stream=$!
sleep 1.5
deviceterm tap 0.5 0.02 --pane "$short" >/dev/null || { kill $stream; rm -f "$contacts"; exit 1; }
sleep 1.5
kill $stream 2>/dev/null
landed=$(grep -c 'new contact' "$contacts")
rm -f "$contacts"

print "tap → backboardd saw $landed new contact(s)"
if (( landed > 0 )); then
    print "PASS: backboardd logged a contact during the tap check"
    exit 0
fi
print "FAIL: the tap reported ok, but no guest contact was logged during the check"
exit 1
