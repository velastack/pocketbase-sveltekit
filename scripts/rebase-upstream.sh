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
# After a successful rebase the script:
#   1. Sets the fork's name/description/repo via `npm pkg set`. The version
#      line is whatever upstream tagged, untouched.
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

echo "==> Fetching $UPSTREAM_REMOTE (with tags)"
git fetch "$UPSTREAM_REMOTE" --tags --prune

echo "==> Fast-forwarding $MASTER_BRANCH -> $UPSTREAM_REMOTE/$MASTER_BRANCH"
git checkout "$MASTER_BRANCH"
git merge --ff-only "$UPSTREAM_REMOTE/$MASTER_BRANCH"

latest_tag="$(git -c 'versionsort.suffix=-' tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort='-version:refname' | head -n1)"
if [ -z "$latest_tag" ]; then
    echo "error: no vX.Y.Z tags found on $UPSTREAM_REMOTE" >&2
    exit 1
fi
target_version="${latest_tag#v}"
echo "==> Latest upstream tag: $latest_tag"

echo "==> Rebasing $PATCH_BRANCH onto $latest_tag"
git checkout "$PATCH_BRANCH"

# Drop the previous run's cleanup commit so the rebase only replays real patches.
# Without this, the cleanup commit's dist deletions would collide with upstream's
# updated dist files every release.
if [ "$(git log -1 --format='%s' HEAD)" = "$CLEANUP_MSG" ]; then
    echo "    dropping previous cleanup commit: $(git log -1 --format='%h %s' HEAD)"
    git reset --hard HEAD~1
fi

if ! git rebase "$latest_tag"; then
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
