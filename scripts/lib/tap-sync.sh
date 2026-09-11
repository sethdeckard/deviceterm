#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/lib/tap-sync.sh: safely synchronize the Homebrew tap before publish.

# Set by dt_sync_tap_checkout and consumed by dt_push_tap_checkout. Keeping the
# resolved destination makes pull and push immune to pushRemote, remote.pushDefault,
# and push.default settings that could otherwise select another remote or ref.
DT_TAP_REMOTE=""
DT_TAP_REMOTE_REF=""

# dt_sync_tap_checkout <tap-checkout>
#   Requires a clean checkout on a branch with an upstream, resolves that
#   upstream's remote and branch, fast-forwards from them explicitly, then
#   confirms it contains no local-only commits. Refuses any state that would
#   require merging or rebasing; a release publisher must not rewrite or
#   accidentally publish unrelated tap work.
dt_sync_tap_checkout() {
    local tap_dir="$1"
    local branch
    local upstream
    local remote
    local remote_ref
    local local_head
    local upstream_head

    DT_TAP_REMOTE=""
    DT_TAP_REMOTE_REF=""

    if ! git -C "$tap_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "tap-sync: not a Git checkout: $tap_dir" >&2
        return 1
    fi

    if [ -n "$(git -C "$tap_dir" status --porcelain --untracked-files=all)" ]; then
        echo "tap-sync: checkout has uncommitted or untracked changes: $tap_dir" >&2
        git -C "$tap_dir" status --short >&2
        return 1
    fi

    branch="$(git -C "$tap_dir" symbolic-ref --quiet --short HEAD)" || {
        echo "tap-sync: checkout is detached; check out the publishing branch: $tap_dir" >&2
        return 1
    }
    upstream="$(git -C "$tap_dir" rev-parse \
        --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || {
        echo "tap-sync: branch '$branch' has no resolvable upstream: $tap_dir" >&2
        return 1
    }
    remote="$(git -C "$tap_dir" config --get "branch.$branch.remote")" || {
        echo "tap-sync: cannot resolve the remote for '$upstream': $tap_dir" >&2
        return 1
    }
    remote_ref="$(git -C "$tap_dir" config --get "branch.$branch.merge")" || {
        echo "tap-sync: cannot resolve the remote ref for '$upstream': $tap_dir" >&2
        return 1
    }
    if [ "$remote" = "." ] || [ -z "$remote" ]; then
        echo "tap-sync: upstream '$upstream' does not use a publishing remote" >&2
        return 1
    fi
    case "$remote_ref" in
        refs/heads/*) ;;
        *)
            echo "tap-sync: upstream '$upstream' is not a remote branch" >&2
            return 1
            ;;
    esac

    printf '  → synchronizing Homebrew tap %s from %s\n' "$branch" "$upstream"
    if ! git -C "$tap_dir" pull --ff-only "$remote" "$remote_ref"; then
        echo "tap-sync: failed to update '$branch' from '$upstream'" >&2
        echo "tap-sync: resolve the Git error above, then retry the publish" >&2
        return 1
    fi

    local_head="$(git -C "$tap_dir" rev-parse HEAD)"
    upstream_head="$(git -C "$tap_dir" rev-parse '@{upstream}')"
    if [ "$local_head" != "$upstream_head" ]; then
        echo "tap-sync: branch '$branch' contains local commits not on '$upstream'" >&2
        echo "tap-sync: publish or reconcile that tap work manually, then retry" >&2
        return 1
    fi

    DT_TAP_REMOTE="$remote"
    DT_TAP_REMOTE_REF="$remote_ref"
}

# dt_push_tap_checkout <tap-checkout>
#   Pushes HEAD to the exact remote branch resolved and synchronized by
#   dt_sync_tap_checkout. An explicit refspec prevents user-level push settings
#   from redirecting the release or including unrelated branches.
dt_push_tap_checkout() {
    local tap_dir="$1"

    if [ -z "$DT_TAP_REMOTE" ] || [ -z "$DT_TAP_REMOTE_REF" ]; then
        echo "tap-sync: push requested before a successful synchronization" >&2
        return 1
    fi
    git -C "$tap_dir" push "$DT_TAP_REMOTE" "HEAD:$DT_TAP_REMOTE_REF"
}
