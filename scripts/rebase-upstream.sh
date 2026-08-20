#!/usr/bin/env bash
#
# Rebase the `sveltekit` patch branch onto the latest upstream release tag
# from pocketbase/js-sdk, and fast-forward `master` to upstream/master.
#
# Assumed branch layout:
#   - remote `upstream` -> pocketbase/js-sdk
#   - remote `origin`   -> velastack/pocketbase-sveltekit
#   - `master` tracks `upstream/master`
#   - `sveltekit` is `master` + our patch commit(s) + a script-managed cleanup
#
# Design:
#   To avoid recurring merge conflicts on every upstream release, fork patches
#   deliberately do NOT touch the package.json version/name/description lines
#   and do NOT delete upstream's dist/ files. Both of those changes are applied
#   AFTER the rebase as a single cleanup commit on the tip — the script drops
#   that cleanup commit before the next rebase, so upstream's patches replay
#   onto a tree that doesn't fight them, then the cleanup is reapplied.
#
#   Our published fork tags (`vX.Y.Z`) share a namespace with upstream's tags,
#   so the script does NOT fetch upstream tags into the local refs/tags/
#   namespace (that would clobber our published-version pointers, or fail).
#   Instead, the latest upstream tag is discovered via `git ls-remote` and the
#   rebase target is the resolved commit SHA. Any leftover local tag that's
#   still pointing at an upstream commit (from an older `--tags` fetch) is
#   cleaned up so `git tag vX.Y.Z` after publish works without --force.
#
# After a successful rebase the script:
#   1. Sets the fork's name/description/repo and the `files` publish allowlist
#      via `npm pkg set`. The version line is whatever upstream tagged,
#      untouched.
#   2. Removes any upstream-tracked dist/* files (the package is built by CI).
#   3. Commits the changes as `sveltekit: pin metadata and drop dist/`.
#
# After this script:
#   - Push the branch:        git push origin sveltekit --force-with-lease
#   - Tag and push the tag:   git tag vX.Y.Z && git push origin vX.Y.Z
#     The tag push triggers .github/workflows/publish.yml which builds and
#     publishes to npm via Trusted Publishing.

set -euo pipefail

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
PATCH_BRANCH="${PATCH_BRANCH:-sveltekit}"
MASTER_BRANCH="${MASTER_BRANCH:-master}"
CLEANUP_MSG="sveltekit: pin metadata and drop dist/"

FORK_NAME="pocketbase-sveltekit"
FORK_DESCRIPTION="PocketBase JavaScript SDK for SvelteKit"
FORK_REPO_URL="git://github.com/velastack/pocketbase-sveltekit.git"

cd "$(git rev-parse --show-toplevel)"

if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree has uncommitted changes. Commit or stash first." >&2
    exit 1
fi

if ! git show-ref --verify --quiet "refs/heads/$PATCH_BRANCH"; then
    echo "error: patch branch '$PATCH_BRANCH' does not exist" >&2
    exit 1
fi

starting_branch="$(git rev-parse --abbrev-ref HEAD)"
restore_branch() {
    [ "$(git rev-parse --abbrev-ref HEAD)" = "$starting_branch" ] && return
    # Don't try to switch away from a branch that's mid-rebase.
    [ -d "$(git rev-parse --git-path rebase-merge)" ] && return
    [ -d "$(git rev-parse --git-path rebase-apply)" ] && return
    git checkout --quiet "$starting_branch" 2>/dev/null || true
}
trap restore_branch EXIT

echo "==> Fetching $UPSTREAM_REMOTE (branches only; tags discovered via ls-remote)"
git fetch "$UPSTREAM_REMOTE" --no-tags --prune

echo "==> Fast-forwarding $MASTER_BRANCH -> $UPSTREAM_REMOTE/$MASTER_BRANCH"
git checkout "$MASTER_BRANCH"
git merge --ff-only "$UPSTREAM_REMOTE/$MASTER_BRANCH"

latest_tag="$(git ls-remote --tags --refs "$UPSTREAM_REMOTE" 'v[0-9]*' \
    | awk '{sub("refs/tags/", "", $2); print $2}' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -n1)"
if [ -z "$latest_tag" ]; then
    echo "error: no vX.Y.Z tags found on $UPSTREAM_REMOTE" >&2
    exit 1
fi
target_version="${latest_tag#v}"
target_sha="$(git ls-remote "$UPSTREAM_REMOTE" "refs/tags/$latest_tag" | awk '{print $1}')"
if [ -z "$target_sha" ]; then
    echo "error: could not resolve $latest_tag on $UPSTREAM_REMOTE" >&2
    exit 1
fi
echo "==> Latest upstream tag: $latest_tag ($target_sha)"

# If there's a stale local tag with this name pointing at the upstream commit
# (leftover from an older --tags fetch), delete it. Without this, the post-
# publish `git tag vX.Y.Z` step fails because the name is already taken. We
# only delete tags that point exactly at the upstream SHA — anything else may
# be a real published-fork pointer worth keeping.
if [ -n "$(git tag --list "$latest_tag")" ]; then
    local_tag_sha="$(git rev-parse "refs/tags/$latest_tag")"
    if [ "$local_tag_sha" = "$target_sha" ]; then
        echo "    removing stale local $latest_tag (was pointing at upstream)"
        git tag -d "$latest_tag" >/dev/null
    fi
fi

echo "==> Rebasing $PATCH_BRANCH onto $latest_tag ($target_sha)"
git checkout "$PATCH_BRANCH"

# Drop any previous cleanup commits from the patch series, wherever they sit.
# The cleanup deletes dist/ and pins package.json metadata; replaying it onto a
# newer upstream (with different dist/ content) is a guaranteed delete/modify
# conflict. We re-apply the cleanup at the end so it doesn't stack.
#
# We look for the cleanup commit anywhere in master..PATCH_BRANCH (not just at
# HEAD) because other fork patches — script edits, workflow tweaks — can land
# on top of it between rebase runs.
while :; do
    cleanup_sha="$(git log --format='%H' --extended-regexp \
        --grep="^${CLEANUP_MSG}\$" \
        "$MASTER_BRANCH..$PATCH_BRANCH" | tail -n1)"
    [ -z "$cleanup_sha" ] && break
    echo "    dropping previous cleanup commit: $(git log -1 --format='%h %s' "$cleanup_sha")"
    if ! git rebase --onto "$cleanup_sha~1" "$cleanup_sha" "$PATCH_BRANCH"; then
        echo "" >&2
        echo "Failed to drop cleanup commit $cleanup_sha." >&2
        echo "Resolve conflicts and run:" >&2
        echo "    git rebase --continue" >&2
        echo "    bash scripts/rebase-upstream.sh   # re-run to finish" >&2
        echo "To give up:" >&2
        echo "    git rebase --abort" >&2
        trap - EXIT
        exit 2
    fi
done

if ! git rebase "$target_sha"; then
    echo "" >&2
    echo "Rebase hit conflicts. Resolve them and run:" >&2
    echo "    git rebase --continue" >&2
    echo "    bash scripts/rebase-upstream.sh   # re-run to apply the cleanup commit" >&2
    echo "To give up:" >&2
    echo "    git rebase --abort" >&2
    trap - EXIT
    exit 2
fi

echo "==> Pinning fork metadata"
npm pkg set "name=$FORK_NAME"
npm pkg set "description=$FORK_DESCRIPTION"
npm pkg set "repository.type=git"
npm pkg set "repository.url=$FORK_REPO_URL"

# Publish only the built package. Upstream's .npmignore is a denylist that
# doesn't cover .github/ or scripts/, so those repo-tooling files were ending
# up in the tarball. An allowlist here beats patching upstream's .npmignore
# (which would conflict on every rebase). npm adds package.json, README and
# LICENSE automatically; CHANGELOG has to be listed explicitly to survive.
npm pkg set "files[0]=dist"
npm pkg set "files[1]=CHANGELOG.md"

if [ -n "$(git ls-files dist/ 2>/dev/null)" ]; then
    echo "==> Removing upstream-tracked dist/ (rebuilt by CI)"
    git rm -rf --quiet dist/
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "==> Committing cleanup"
    git add -A
    git commit --quiet -m "$CLEANUP_MSG"
else
    echo "==> Nothing to clean up (already in sync)"
fi

pkg_version="$(node -p "require('./package.json').version" 2>/dev/null || echo "")"
if [ -n "$pkg_version" ] && [ "$pkg_version" != "$target_version" ]; then
    echo "warning: package.json version is $pkg_version, expected $target_version" >&2
fi

master_sha="$(git rev-parse --short "$MASTER_BRANCH")"
patch_sha="$(git rev-parse --short "$PATCH_BRANCH")"

cat <<EOF

==> Done.
    $MASTER_BRANCH   $master_sha  ($UPSTREAM_REMOTE/$MASTER_BRANCH)
    $PATCH_BRANCH $patch_sha  (based on $latest_tag, package version $pkg_version)

Next steps:
    npm install --legacy-peer-deps && npm test
    git push $ORIGIN_REMOTE $PATCH_BRANCH --force-with-lease
    git tag v$target_version && git push $ORIGIN_REMOTE v$target_version
        (tag push triggers .github/workflows/publish.yml -> npm publish)
EOF
