#!/usr/bin/env bash
# Keep a fork current with the upstream it was forked from.
#
# Only relevant when this repo has BOTH an "origin" (the fork firstmate ships
# PRs to) and an "upstream" (the repo the fork tracks). A single-remote install,
# where origin IS upstream, has no upstream remote and is skipped silently, so
# this script is inert for everyone who has not forked.
#
# FAST-FORWARD ONLY, exactly like fm-fleet-sync.sh. The fork is advanced only
# when upstream/<default> strictly contains origin/<default>. A diverged fork -
# one that is BOTH ahead and behind, so there is no fast-forward - may hold real
# unlanded work, so it is left completely untouched and reported as a loud,
# quantified "STUCK: ... - needs attention" line. This script never rebases,
# never force pushes, never stashes, and never discards work; a divergence is a
# human decision, not an automatic one.
#
# Being only AHEAD is not drift. That is the normal resting state of a fork
# carrying its own work on top of a fully-merged upstream, and it reports as
# current; treating it as drift would alarm on every run for as long as the fork
# has work of its own. Only being behind is drift.
#
# Two levels of action, so nothing moves until a human asks for it:
#   default   REPORT ONLY. Fetch both remotes and report how far the fork is
#             behind. No branch is moved and nothing is pushed. This is what the
#             session-start sweep runs, and a routine sweep must never mutate a
#             branch nobody asked it to move.
#   --push    fast-forward the FORK by pushing the upstream commit to origin,
#             then fast-forward the local default branch to match. Refuses on a
#             diverged fork. Run this when the report says the fork is behind.
#             This is an outward-facing write to a shared default branch, so it
#             is a human-invoked command, never something an agent or a sweep
#             runs on its own.
#   --sweep   mark the run as UNATTENDED: no terminal is watching and stderr is
#             discarded by the caller, so git must never sit on a credential or
#             passphrase prompt. Bootstrap passes this. It cannot be combined
#             with --push, because a prompt-free guarantee only makes sense when
#             nobody is there to answer the prompt; a human who typed --push
#             gets ordinary interactive authentication.
#
# The local fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode is the
# fetched upstream commit, so there is one ff implementation, not several).
#
# Output is one line per outcome, in fm-fleet-sync.sh's vocabulary:
#   "firstmate: skipped: <reason>"        benign, nothing to do
#   "firstmate: current"                  fork already matches upstream
#   "firstmate: behind: <detail>"         fork is fast-forwardable; run --push
#   "firstmate: updated: <detail>"        the fork was advanced (--push only)
#   "firstmate: STUCK: <detail>"          diverged; left untouched, needs a human
#
# STUCK is reserved for a branch-shaped problem a human must reconcile: a
# diverged fork, or a push git rejected as a non-fast-forward. A remote that
# could not be reached or authenticated is NOT stuck - nothing about the
# branches is wrong - so it reports as a skip naming credentials or the network,
# which points at the real cause instead of sending the operator to read history.
#
# Exit status: 0 whenever the run said what it found, including a report-only
# STUCK. --push exits 1 whenever it was asked to advance the fork and did not,
# whether because the fork diverged, the push was rejected, or origin could not
# be reached, so a scripted caller can tell a refusal from a success without
# parsing the output.
#
# Usage: fm-upstream-sync.sh [--push] [--sweep] [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

# The remote holding the upstream project. Overridable so the tests can build a
# fixture without inventing a second convention.
UPSTREAM_REMOTE="${FM_UPSTREAM_REMOTE:-upstream}"
LABEL=firstmate
PUSH=no
SWEEP=no

usage() {
  sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=yes ;;
    --sweep) SWEEP=yes ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown argument '$1' (usage: fm-upstream-sync.sh [--push] [--sweep])" >&2; exit 2 ;;
  esac
  shift
done

if [ "$PUSH" = yes ] && [ "$SWEEP" = yes ]; then
  echo "error: --sweep is unattended and cannot be combined with --push" >&2
  exit 2
fi

# Unattended only. Nobody is watching this run and the caller discards stderr, so
# an interactive prompt would be an invisible hang; an unauthenticated remote must
# fail fast and report a skip instead. A human who deliberately typed the command
# keeps ordinary interactive authentication, because an ssh-agent-less operator
# with a passphrase-protected key must still be able to answer for themselves.
#
# GIT_TERMINAL_PROMPT does not cover ssh's own passphrase prompt, so BatchMode is
# forced too, and it is PREPENDED immediately after the program word rather than
# appended: ssh uses the FIRST obtained value for each parameter, so an option
# added after an operator's own -o BatchMode=no would be ignored.
if [ "$SWEEP" = yes ]; then
  export GIT_TERMINAL_PROMPT=0
  if [ -n "${GIT_SSH_COMMAND:-}" ]; then
    read -r ssh_prog ssh_rest <<<"$GIT_SSH_COMMAND"
    export GIT_SSH_COMMAND="$ssh_prog -o BatchMode=yes${ssh_rest:+ $ssh_rest}"
  else
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes"
  fi
fi

# An unattended run has no terminal to write to and its caller throws stderr away.
# A human run gets git's own diagnostic, which is the only place the real cause of
# an authentication or network failure is spelled out.
relay_git_error() {  # <text>
  [ "$SWEEP" = yes ] && return 0
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | sed 's/^/  /' >&2
}

# Report and exit 0: an absent upstream remote is the normal single-remote
# install, not a problem to escalate.
if ! git -C "$FM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "$LABEL: skipped: not a git repo"
  exit 0
fi
if ! git -C "$FM_ROOT" remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  echo "$LABEL: skipped: no $UPSTREAM_REMOTE remote"
  exit 0
fi
if ! git -C "$FM_ROOT" remote get-url origin >/dev/null 2>&1; then
  echo "$LABEL: skipped: no origin remote"
  exit 0
fi

DEFAULT=$(default_branch "$FM_ROOT") || {
  echo "$LABEL: skipped: cannot determine default branch"
  exit 0
}

# A fetch that fails says nothing about the branches, so it is a skip naming the
# network or credentials rather than a STUCK that would send the operator off to
# read history for a problem that is actually a key or a missing connection.
fetch_remote() {  # <remote>
  local remote=$1 err
  if ! err=$(git -C "$FM_ROOT" fetch "$remote" --quiet 2>&1); then
    echo "$LABEL: skipped: cannot reach $remote (network or credentials)"
    relay_git_error "$err"
    return 1
  fi
  return 0
}

fetch_remote "$UPSTREAM_REMOTE" || exit 0
# origin too, because the whole classification below is read off origin/<default>.
# A stale remote-tracking ref would under-report the fork's own commits and turn a
# genuine divergence into a clean "behind", which is precisely the case that must
# never be advanced automatically. Never classify against data we failed to refresh.
fetch_remote origin || exit 0

UPSTREAM_REF="$UPSTREAM_REMOTE/$DEFAULT"
ORIGIN_REF="origin/$DEFAULT"
if ! UPSTREAM_REV=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$UPSTREAM_REF^{commit}"); then
  echo "$LABEL: skipped: $UPSTREAM_REF does not exist"
  exit 0
fi
if ! ORIGIN_REV=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$ORIGIN_REF^{commit}"); then
  echo "$LABEL: skipped: $ORIGIN_REF does not exist"
  exit 0
fi

# Ahead/behind of the FORK relative to upstream. "ahead" is the fork's own
# unlanded work, which is exactly what must never be rewritten automatically.
counts=$(git -C "$FM_ROOT" rev-list --left-right --count "$ORIGIN_REV...$UPSTREAM_REV" 2>/dev/null) || {
  echo "$LABEL: skipped: cannot compare $ORIGIN_REF with $UPSTREAM_REF"
  exit 0
}
AHEAD=$(printf '%s\n' "$counts" | awk '{print $1}')
BEHIND=$(printf '%s\n' "$counts" | awk '{print $2}')

# Nothing upstream to take. A fork that is only AHEAD is the normal healthy
# state - it carries its own work on top of a fully-merged upstream - so it is
# reported as current, not as drift. Only being behind is drift.
if [ "$BEHIND" -eq 0 ]; then
  echo "$LABEL: current"
  exit 0
fi

# Diverged: the fork holds commits upstream does not AND is missing commits
# upstream has, so there is no fast-forward. Bringing it forward would mean a
# rebase and a force push, which is a deliberate human operation with a backup
# taken first, never an automatic sweep. Leave it strictly alone.
if [ "$AHEAD" -gt 0 ]; then
  echo "$LABEL: STUCK: fork has diverged from $UPSTREAM_REF, $AHEAD ahead and $BEHIND behind - needs attention, reconcile it by hand"
  # A report-only run did its job and exits 0. --push was asked to advance the
  # fork and did not, which is the same refusal as a rejected push below, so it
  # exits the same way rather than looking like a success to a scripted caller.
  if [ "$PUSH" = yes ]; then
    exit 1
  fi
  exit 0
fi

# Strictly behind: a genuine fast-forward. The default run reports it and stops.
# It deliberately does NOT move the local default branch: a routine session-start
# sweep that silently advances a branch is exactly the kind of surprise this
# feature exists to prevent, and it would leave the local branch ahead of the
# fork's origin. Moving anything is --push's job, because a human asked for it.
if [ "$PUSH" != yes ]; then
  echo "$LABEL: behind: fork is $BEHIND commits behind $UPSTREAM_REF; run bin/fm-upstream-sync.sh --push to fast-forward it"
  exit 0
fi

# --push: fast-forward the fork itself. The refspec is an ordinary (non-forced)
# push, so git itself is the final guard: if origin has moved in a way that is
# no longer a fast-forward, the push is rejected rather than overwriting it.
if ! out=$(git -C "$FM_ROOT" push origin "$UPSTREAM_REV:refs/heads/$DEFAULT" 2>&1); then
  # Two very different failures wear the same non-zero exit. Only a ref git
  # actually refused is a branch problem worth a STUCK; anything else means the
  # push never got far enough to have an opinion about branches, so it reports as
  # a skip naming the real cause instead of pointing at history.
  case "$out" in
    *'[rejected]'*|*'non-fast-forward'*|*'fetch first'*|*'stale info'*)
      echo "$LABEL: STUCK: fast-forward push to origin/$DEFAULT was rejected as a non-fast-forward - needs attention" ;;
    *)
      echo "$LABEL: skipped: cannot push to origin (network or credentials)" ;;
  esac
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  exit 1
fi
# The fork itself has moved. Bringing the local default branch along is a second,
# independent step that ff_target legitimately declines whenever the checkout is
# dirty, detached, or sitting on a feature branch - which is the COMMON case,
# since a feature branch is where an operator usually is when they run this. So
# capture its outcome instead of discarding it: reporting a bare "fast-forwarded"
# when only origin moved would leave the local branch quietly stranded, and the
# next default run compares origin against upstream and reports current.
# ff_target sets FF_STATUS in this shell, so its output goes to a file rather
# than a command substitution, which would run it in a subshell.
FF_LINE=""
if FF_LOG=$(mktemp "${TMPDIR:-/tmp}/fm-upstream-ff.XXXXXX" 2>/dev/null); then
  ff_target "$FM_ROOT" "$LABEL" "$UPSTREAM_REV" no no >"$FF_LOG" 2>&1 || true
  FF_LINE=$(sed -n '1p' "$FF_LOG")
  rm -f "$FF_LOG"
else
  ff_target "$FM_ROOT" "$LABEL" "$UPSTREAM_REV" no no >/dev/null 2>&1 || true
fi

UPDATED="$LABEL: updated: fork fast-forwarded $BEHIND commits to $UPSTREAM_REF"
if [ "$FF_STATUS" = updated ] || [ "$FF_STATUS" = current ]; then
  echo "$UPDATED"
else
  REASON=${FF_LINE#"$LABEL: skipped: "}
  echo "$UPDATED; local $DEFAULT branch not moved${REASON:+: $REASON}"
fi
