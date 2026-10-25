#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/pane-snapshot.sh: capture what a simulator pane draws, frame by
# frame, from the dev seat's running debug build.
#
#   scripts/pane-snapshot.sh <udid> <seconds> <out-dir>
#
# Writes a request into the seat's snapshots/requests directory and waits
# for the app's answer. The frames the pane draws for <seconds> (at most
# 5) land in <out-dir> as NNNN.png, bezel included, with frames.json
# listing each one's time and what the pane was drawing; a frame that
# can't be read back is skipped. Run it alongside `deviceterm fold …` to
# capture a fold.
#
# Only the seat's own debug build captures (make bless, then make run in
# that checkout), and only a pane that is on screen. A seat build that has
# since lost the seat refuses. With no seat build running, nothing answers;
# this gives up after the burst plus a margin and removes the request.

set -euo pipefail

[ $# -eq 3 ] || { echo "usage: pane-snapshot.sh <udid> <seconds> <out-dir>" >&2; exit 64; }
udid="$1"
seconds="$2"
case "$3" in
    /*) out="$3" ;;
    *)  out="$(pwd -P)/$3" ;;
esac

requests="/tmp/deviceterm.$(id -u).seat/snapshots/requests"
if [ ! -d "$requests" ]; then
    echo "pane-snapshot: $requests is missing; is the dev seat's build running?" >&2
    exit 1
fi

id="snap-$$-$(date +%s)"
# Renamed into place whole, so the app never reads half a request.
# JSON from a real encoder, so a path with quotes or backslashes stays intact.
# A seconds value that isn't a number encodes as null, which the app refuses.
osascript -l JavaScript -e '
    function run(argv) {
        return JSON.stringify({ udid: argv[0], seconds: Number(argv[1]), out: argv[2] })
    }' "$udid" "$seconds" "$out" > "$requests/$id.tmp"
mv "$requests/$id.tmp" "$requests/$id.json"

done_file="$requests/$id.done.json"
# The burst, then time to write its frames.
limit=$(awk -v s="$seconds" 'BEGIN { printf "%d", (s + 30) * 10 }')
for _ in $(seq 1 "$limit"); do
    [ -f "$done_file" ] && break
    sleep 0.1
done
if [ ! -f "$done_file" ]; then
    rm -f "$requests/$id.json"
    echo "pane-snapshot: no answer; is the dev seat's debug build running?" >&2
    exit 1
fi
answer=$(cat "$done_file")
rm -f "$done_file"
echo "$answer"
case "$answer" in
    *'"ok":true'*) echo "pane-snapshot: frames in $out" ;;
    *) exit 1 ;;
esac
