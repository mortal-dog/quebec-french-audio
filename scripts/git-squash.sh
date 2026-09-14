#!/usr/bin/env bash
set -euo pipefail

# Squash all history on the current branch into one commit and force-push it.
#
#   pnpm git:squash
#   SQUASH_OVERWRITE_REMOTE=1 pnpm git:squash    # skip the remote check (see below)
#
# This repo keeps a single commit on purpose, so this script is the normal way to record
# work rather than a rare surgical tool. Every path through it ends in a force push, which
# is why most of the code below is about not destroying anything on the way there.
#
# WHY THIS REPO IN PARTICULAR CANNOT KEEP HISTORY
# -----------------------------------------------
# site/audio/ holds ~511 MB of audio pack, split into <=90 MB pieces because git rejects
# files over 100 MB. Those pieces are BINARY and they change wholesale whenever the corpus
# is re-synthesized — git cannot delta them, so every republish would add another ~511 MB
# to history that nothing will ever read again. Three rebuilds and the repo is past the
# 1 GB GitHub warns at; a few more and clones stop being practical.
#
# Folding into one commit means the repo stays the size of its CONTENTS rather than the sum
# of everything it has ever contained. Note what this does NOT do: the objects this push
# orphans stay on GitHub's side until their garbage collector runs, so the remote does not
# shrink the moment you force-push. It stops growing, which is the part that matters.
#
# TWO SHAPES THAT ARE DELIBERATELY NOT "IMPROVED"
# ----------------------------------------------
#   1. Run it on `main` only. The rewrite uses `git checkout --orphan`, so the branch it
#      produces shares NO ancestor with anything. Run it on a feature branch and that
#      branch can never be merged back.
#   2. It force-pushes. That is the point — a squashed history cannot fast-forward over
#      what it replaced.
#
# Making either one more convenient would only make it easier to step on.

echo "══════════════════════════════════════════════════════════════"
echo "⚠️  GIT SQUASH: Squash ALL history into a single commit"
echo "══════════════════════════════════════════════════════════════"

CURRENT_BRANCH=$(git branch --show-current)
if [[ -z "$CURRENT_BRANCH" ]]; then
  echo "❌ ERROR: Not currently on any branch."
  exit 1
fi

# ── Ask origin what it holds before force-pushing over it ────────────────────
#
# A force push with no look at the remote deletes whatever landed there since this tree was
# last updated, and prints nothing while doing it. Anything pushed from another machine — or
# another clone on this one — is gone with no record that it existed.
#
# The test is an ANCESTOR relationship, not a path diff: after a squash the two sides have no
# common ancestor to diff meaningfully, so the only honest question is "is the remote tip
# already contained in my history?" Yes → pushing loses nothing. No → this push is a delete.
#
# When the remote cannot be seen, REFUSE rather than proceed. "Could not read it" is not the
# same as "it is safe", and a force push that never saw the remote cannot claim to be
# idempotent. To push anyway, say so explicitly:
#   SQUASH_OVERWRITE_REMOTE=1 pnpm git:squash
OVERWRITE=${SQUASH_OVERWRITE_REMOTE:-0}

# The guard is check-then-act: it fetches here, but the push happens dozens of lines later.
# A bare `-f` would not re-check in that window, so a push landing inside it is lost anyway.
#
# `--force-with-lease` carries "the state I looked at" to the moment of the push and lets git
# compare atomically. The expected commit MUST be given explicitly: a bare
# `--force-with-lease` trusts the local remote-tracking ref, which is *always* fresh right
# after a fetch — exactly no protection against this race. FETCH_HEAD is what the guard
# actually saw.
#
# The default is an empty expected value (`<ref>:`), which git reads as "this ref must not
# exist". That is correct when the remote has no such branch yet, and it also blocks the case
# where ls-remote said "absent" and someone created it before the push.
PUSH_LEASE="--force-with-lease=refs/heads/$CURRENT_BRANCH:"

if [[ "$OVERWRITE" != "1" ]]; then
  echo "→ Checking what origin/$CURRENT_BRANCH holds before force-pushing over it..."
  set +e
  git ls-remote --exit-code --heads origin "$CURRENT_BRANCH" >/dev/null 2>&1
  LS_RC=$?
  set -e
  if [[ "$LS_RC" -eq 0 ]]; then
    if ! git fetch --quiet origin "$CURRENT_BRANCH"; then
      echo "❌ ERROR: origin/$CURRENT_BRANCH exists but could not be fetched."
      echo "   Refusing to force-push over a remote this script cannot see."
      echo "   Re-run with SQUASH_OVERWRITE_REMOTE=1 to overwrite it anyway."
      exit 1
    fi
    # From here the guard has "seen" the remote. Every path that proceeds ends at the push,
    # and the push carries this commit as its expected value — so if the remote moves after
    # this fetch, git rejects the push atomically.
    PUSH_LEASE="--force-with-lease=refs/heads/$CURRENT_BRANCH:$(git rev-parse FETCH_HEAD)"
    # If the ancestor test fails, ask one more question: what about the tree? This history is
    # disposable by design (everything folds into one commit, so short hashes never survive),
    # which means losing a commit OBJECT is not losing anything — losing CONTENT is. When the
    # two trees are byte-identical, the loss from this push is provably zero.
    #
    # This does NOT cover "retry after a push failed partway". In that case the local tree has
    # just folded in new work, so the trees differ and it falls through to the refusal below.
    # That is intended: after a genuinely failed push nobody knows where the remote stopped,
    # and a human should look at the evidence.
    if git merge-base --is-ancestor FETCH_HEAD HEAD; then
      echo "  ✓ origin/$CURRENT_BRANCH is already contained in this history."
    elif git diff --quiet HEAD FETCH_HEAD; then
      echo "  ✓ origin/$CURRENT_BRANCH is a different commit but an identical tree — nothing to lose."
    else
      echo "❌ ERROR: origin/$CURRENT_BRANCH has commits this working tree does not contain."
      echo "   A force push would DELETE them."
      echo ""
      git --no-pager log --oneline HEAD..FETCH_HEAD || true
      echo ""
      echo "   --- what differs between this tree and origin ---"
      git --no-pager diff --stat HEAD FETCH_HEAD || true
      echo ""
      echo "   Fix:      git pull --rebase origin $CURRENT_BRANCH   (then re-run)"
      echo "   Override: SQUASH_OVERWRITE_REMOTE=1 pnpm git:squash"
      exit 1
    fi
  elif [[ "$LS_RC" -eq 2 ]]; then
    # `--exit-code` returns 2 for "the remote answered, but has no such ref" — nothing to lose.
    echo "  ✓ origin has no $CURRENT_BRANCH yet — nothing to overwrite."
  else
    echo "❌ ERROR: could not reach origin (git ls-remote exit $LS_RC)."
    echo "   Refusing to force-push over a remote this script cannot see."
    echo "   Re-run with SQUASH_OVERWRITE_REMOTE=1 to overwrite it anyway."
    exit 1
  fi
else
  echo "⚠️  SQUASH_OVERWRITE_REMOTE=1 — skipping the remote check, origin will be overwritten."
  # This switch means exactly "whatever is on the remote, replace it with my tree". A lease is
  # self-contradictory here: without a fetch there is no "state I looked at" to lease against.
  PUSH_LEASE="--force"
fi

# Conflict markers must never be squashed into the snapshot. A tree with unmerged paths taken
# by `git add -A` and committed with `--no-verify` puts `<<<<<<<` on main and flattens the
# history in the same motion.
assert_no_unmerged_paths() {
  if git ls-files -u | grep -q .; then
    echo "❌ ERROR: unmerged paths in the working tree — refusing to squash conflict markers."
    echo "   These:"
    git ls-files -u | awk '{print "     " $4}' | sort -u
    echo "   Resolve the conflict (or git merge --abort), then re-run."
    exit 1
  fi
}

# Before any modification. Placed here rather than beside the two `git add -A` calls: the
# orphan-branch path would otherwise hit git's own "you need to resolve your current index
# first", which is true but does not explain why THIS script in particular must not continue —
# its next steps are `commit --no-verify` and a force push.
assert_no_unmerged_paths

# 1. Idempotency check: with only one commit, fold the current changes into it.
COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo "0")
if [[ "$COMMIT_COUNT" -eq 1 ]]; then
  echo "→ Repository already has only 1 commit. Folding all changes into it..."
  git add -A
  # --no-verify skips commit hooks. This repo currently installs none (`core.hooksPath` is
  # unset and there is no `scripts/pre-commit`), so today it skips nothing — but it is kept so
  # that adding a hook later does not silently make the end-of-session squash wait on a lint.
  #
  # The Pages workflow deploys whatever lands on main, so a squash here publishes
  # immediately. `french.doctornova.net/privacy` is the URL Google Play checks — look at
  # what you are about to push before you push it.
  git commit --amend -m "feat: initial commit" --no-verify
  git push "$PUSH_LEASE" origin "$CURRENT_BRANCH"
  echo "✅ Changes folded into the single 'feat: initial commit'."
  exit 0
fi

echo "  This will DYNAMICALLY FIND AND DELETE:"
echo "    • All of your commit history on the current branch"
echo "    • It will then force push a single 'feat: initial commit' commit"
echo "    • This is destructive and irreversible!"
echo ""
echo ""

# The guard above already established that the remote tip is an ancestor of local, so this
# pull is necessarily a no-op. It is kept because the guard can be switched off.
#
# No `|| true`: with the guard on, the premise holds, so a failed pull means the premise broke
# — most likely a real conflict — and continuing automatically would be guessing. The conflict
# that `|| true` would swallow is one the next `git add -A` would stage, markers and all.
#
# With the guard explicitly off, skip the step entirely: the operator said "replace the remote
# with my tree", so merging the remote in first is self-contradictory, and it is precisely the
# pull most likely to conflict.
if [[ "$OVERWRITE" != "1" ]]; then
  echo "→ Pulling latest changes from origin..."
  if ! git pull origin "$CURRENT_BRANCH"; then
    echo "❌ ERROR: pull failed (most likely a real conflict) — squash aborted." >&2
    echo "   Inspect the working tree before re-running." >&2
    exit 1
  fi
else
  echo "→ Skipping pull (SQUASH_OVERWRITE_REMOTE=1 — this tree is meant to replace the remote)."
fi

echo "→ Creating orphan branch..."
git checkout --orphan temp_squash_branch

echo "→ Adding all files..."
git add -A

echo "→ Committing as 'feat: initial commit'..."
# --no-verify for the same reason as above.
git commit -m "feat: initial commit" --no-verify

echo "→ Replacing $CURRENT_BRANCH..."
git branch -D "$CURRENT_BRANCH"
git branch -m "$CURRENT_BRANCH"

echo "→ Force pushing to origin..."
git push "$PUSH_LEASE" origin "$CURRENT_BRANCH"

echo "✅ Git history squashed to a single commit!"
# Uses $CURRENT_BRANCH, not a hardcoded `origin/main main`. This line runs AFTER the force
# push, so on any other branch the damage is already done by the time a hardcoded name fails
# and `set -e` exits — which reads as "the squash failed" when in fact it succeeded, elsewhere.
git branch --set-upstream-to="origin/$CURRENT_BRANCH" "$CURRENT_BRANCH"
