#!/usr/bin/env bash
#
# Rebase the `sveltekit` patch branch onto the latest upstream release tag
# from pocketbase/js-sdk, and fast-forward `master` to upstream/master.
#
# Assumed branch layout:
#   - remote `upstream` -> pocketbase/js-sdk
#   - remote `origin`   -> velastack/pocketbase-sveltekit
#   - `master` tracks `upstream/master`
#   - `sveltekit` is `master` + our patch commit(s)
#
# The package.json version line is inherited from the upstream tag (our patch
# commit does not modify the version), so rebasing onto vX.Y.Z automatically
# produces a package.json that matches the upstream version.
#
# After a successful rebase the script also rebuilds dist/ and commits it as
# `sveltekit: rebuild dist` on top of the patch. A prior dist-only tip commit
# is dropped before the rebase so only source patches get replayed. The build
# uses whatever Node is currently active — run `pnpm env use --global 18`
# yourself before invoking this script (switching Node mid-script isn't
# reliable across shells).

set -euo pipefail

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
PATCH_BRANCH="${PATCH_BRANCH:-sveltekit}"
MASTER_BRANCH="${MASTER_BRANCH:-master}"

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

# If the tip commit only touches dist/ files, it's a previous build commit.
# Drop it before rebasing so only source patches get replayed — otherwise a
# stale dist diff would conflict against the new upstream's dist.
pre_drop_sha=""
tip_files="$(git log -1 --format= --name-only HEAD)"
if [ -n "$tip_files" ] && ! printf '%s\n' "$tip_files" | grep -qv '^dist/'; then
    pre_drop_sha="$(git rev-parse HEAD)"
    echo "    dropping prior dist-only tip: $(git log -1 --format='%h %s' HEAD)"
    git reset --hard HEAD~1
fi

if ! git rebase "$latest_tag"; then
    echo "" >&2
    echo "Rebase hit conflicts. Resolve them and run: git rebase --continue" >&2
    echo "To give up:                              git rebase --abort" >&2
    if [ -n "$pre_drop_sha" ]; then
        echo "(Dropped prior dist tip: $pre_drop_sha — 'git reset --hard $pre_drop_sha' to recover.)" >&2
    fi
    trap - EXIT
    exit 2
fi

# The patch commit deliberately does not touch the version line, so after rebase
# the version should equal the upstream tag. Warn if it drifted (likely means a
# future patch commit started pinning the version — fix it there, not here).
pkg_version="$(node -p "require('./package.json').version" 2>/dev/null || echo "")"
if [ -n "$pkg_version" ] && [ "$pkg_version" != "$target_version" ]; then
    echo "warning: package.json version is $pkg_version, expected $target_version" >&2
    echo "         the patch commit is pinning the version — unpin it there." >&2
fi

echo "==> Installing dependencies (node $(node -v))"
if ! npm install --legacy-peer-deps; then
    echo "error: npm install failed." >&2
    if [ -n "$pre_drop_sha" ]; then
        echo "(Dropped prior dist tip: $pre_drop_sha.)" >&2
    fi
    trap - EXIT
    exit 3
fi

echo "==> Building dist"
if ! npm run build; then
    echo "error: build failed." >&2
    if [ -n "$pre_drop_sha" ]; then
        echo "(Dropped prior dist tip: $pre_drop_sha.)" >&2
    fi
    trap - EXIT
    exit 3
fi

if [ -n "$(git status --porcelain -- dist/)" ]; then
    echo "==> Committing rebuilt dist"
    git add -- dist/
    git commit --quiet -m "sveltekit: rebuild dist"
else
    echo "==> Build produced no dist changes; skipping commit"
fi

master_sha="$(git rev-parse --short "$MASTER_BRANCH")"
patch_sha="$(git rev-parse --short "$PATCH_BRANCH")"

cat <<EOF

==> Done.
    $MASTER_BRANCH   $master_sha  ($UPSTREAM_REMOTE/$MASTER_BRANCH)
    $PATCH_BRANCH $patch_sha  (based on $latest_tag, package version $pkg_version)

Next steps:
    npm test
    git push $ORIGIN_REMOTE $PATCH_BRANCH --force-with-lease
    git tag v$target_version && git push $ORIGIN_REMOTE v$target_version
EOF
