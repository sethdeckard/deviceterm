#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Functional tests for the publish-time Homebrew tap synchronization.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/tap-sync.sh
. "$ROOT/scripts/lib/tap-sync.sh"

TEST_ROOT="$(mktemp -d -t deviceterm-tap-sync-test.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

REMOTE="$TEST_ROOT/homebrew-tap.git"
SEED="$TEST_ROOT/seed"
TAP="$TEST_ROOT/tap"
PEER="$TEST_ROOT/peer"
WRONG_REMOTE="$TEST_ROOT/wrong-remote.git"

commit() {
    git -C "$1" -c user.name=DeviceTerm -c user.email=test@deviceterm.local \
        -c commit.gpgsign=false commit -m "$2" >/dev/null
}

git init --bare --initial-branch=main "$REMOTE" >/dev/null
git clone "$REMOTE" "$SEED" >/dev/null 2>&1
mkdir -p "$SEED/Casks"
printf 'version "0.1.0"\n' > "$SEED/Casks/deviceterm.rb"
git -C "$SEED" add Casks/deviceterm.rb
commit "$SEED" "Initial cask"
git -C "$SEED" push -u origin main >/dev/null 2>&1

git clone "$REMOTE" "$TAP" >/dev/null 2>&1
git clone "$REMOTE" "$PEER" >/dev/null 2>&1
printf 'remote update\n' > "$PEER/README.md"
git -C "$PEER" add README.md
commit "$PEER" "Update tap remotely"
git -C "$PEER" push >/dev/null 2>&1
git clone --bare "$REMOTE" "$WRONG_REMOTE" >/dev/null 2>&1
wrong_head="$(git --git-dir="$WRONG_REMOTE" rev-parse refs/heads/main)"
git -C "$TAP" remote add wrong "$WRONG_REMOTE"
git -C "$TAP" config branch.main.pushRemote wrong
git -C "$TAP" config push.default matching

# A clean checkout behind its upstream is updated automatically.
dt_sync_tap_checkout "$TAP" >/dev/null 2>&1
[ "$(git -C "$TAP" rev-parse HEAD)" = "$(git -C "$TAP" rev-parse '@{upstream}')" ]
[ "$(cat "$TAP/README.md")" = "remote update" ]
[ "$DT_TAP_REMOTE" = "origin" ]
[ "$DT_TAP_REMOTE_REF" = "refs/heads/main" ]

# The push returns to that same upstream even when push-specific configuration
# names another remote and requests all matching branches.
printf 'release cask\n' >> "$TAP/Casks/deviceterm.rb"
git -C "$TAP" add Casks/deviceterm.rb
commit "$TAP" "Publish release cask"
dt_push_tap_checkout "$TAP" >/dev/null 2>&1
[ "$(git --git-dir="$REMOTE" rev-parse refs/heads/main)" = "$(git -C "$TAP" rev-parse HEAD)" ]
[ "$(git --git-dir="$WRONG_REMOTE" rev-parse refs/heads/main)" = "$wrong_head" ]

# Local filesystem changes are never overwritten or carried into a release.
printf 'local work\n' > "$TAP/local.txt"
if dt_sync_tap_checkout "$TAP" >/dev/null 2>&1; then
    echo "test-publish-tap-sync: dirty checkout was accepted" >&2
    exit 1
fi
rm "$TAP/local.txt"

# Local-only commits are not pushed as an accidental part of the release.
printf 'local commit\n' > "$TAP/local.txt"
git -C "$TAP" add local.txt
commit "$TAP" "Unpublished local work"
if dt_sync_tap_checkout "$TAP" >/dev/null 2>&1; then
    echo "test-publish-tap-sync: ahead checkout was accepted" >&2
    exit 1
fi

# Diverged histories fail instead of invoking a merge or rebase.
git clone "$REMOTE" "$TEST_ROOT/diverged" >/dev/null 2>&1
printf 'diverged local\n' > "$TEST_ROOT/diverged/local.txt"
git -C "$TEST_ROOT/diverged" add local.txt
commit "$TEST_ROOT/diverged" "Diverged local work"
git -C "$PEER" pull --ff-only >/dev/null 2>&1
printf 'another remote update\n' >> "$PEER/README.md"
git -C "$PEER" add README.md
commit "$PEER" "Advance remote again"
git -C "$PEER" push >/dev/null 2>&1
diverged_head="$(git -C "$TEST_ROOT/diverged" rev-parse HEAD)"
if diverged_error="$(dt_sync_tap_checkout "$TEST_ROOT/diverged" 2>&1)"; then
    echo "test-publish-tap-sync: diverged checkout was accepted" >&2
    exit 1
fi
[ "$(git -C "$TEST_ROOT/diverged" rev-parse HEAD)" = "$diverged_head" ]
grep -qF "tap-sync: failed to update 'main' from 'origin/main'" <<<"$diverged_error"
grep -qF "tap-sync: resolve the Git error above, then retry the publish" <<<"$diverged_error"

# A configured upstream whose tracking ref cannot resolve gets the broader
# diagnostic rather than being reported as absent.
git clone "$REMOTE" "$TEST_ROOT/unresolvable" >/dev/null 2>&1
git -C "$TEST_ROOT/unresolvable" config branch.main.merge refs/heads/missing
if upstream_error="$(dt_sync_tap_checkout "$TEST_ROOT/unresolvable" 2>&1)"; then
    echo "test-publish-tap-sync: unresolvable upstream was accepted" >&2
    exit 1
fi
grep -qF "tap-sync: branch 'main' has no resolvable upstream" <<<"$upstream_error"

echo "test-publish-tap-sync: ok"
