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
#   --push    fast-forward the FORK by pushing the upstream commit to origin. On
#             a run that actually advanced the fork it then tries to bring the
#             local default branch along; a run that found the fork already level
#             with upstream reports current and moves nothing, because the
#             ordinary local pull belongs to /updatefirstmate, not here.
#             Refuses on a diverged fork. Run this when the report says behind.
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
# diverged fork, or a push origin refused because the branches actually moved
# apart. A remote that could not be reached or authenticated is NOT stuck -
# nothing about the branches is wrong - so it reports as a skip naming
# credentials or the network, which points at the real cause instead of sending
# the operator to read history for what is really a key.
#
# That distinction is drawn STRUCTURALLY, never by reading git's prose: those
# strings are translated, so on a non-English machine a genuine non-fast-forward
# would fall through to the benign arm and invert the one signal this script
# exists to raise. After a failed push the script re-reads origin and follows the
# refs. If origin/<default> is still an ancestor of the upstream commit, the push
# WOULD have been a clean fast-forward, so the branches are provably fine and the
# refusal was about reaching or authenticating to origin - a fetch is anonymous
# while a push needs a write token, so this is the ordinary shape of an expired,
# missing, or read-only credential. Only refs that positively show the push was
# no longer a fast-forward are STUCK. Refs that cannot be read at all are the one
# genuinely ambiguous case, and that is reported loudly rather than downgraded.
#
# One more ref shape is benign: origin may have moved to a DESCENDANT of the
# commit we tried to push, which is what GitHub's "Sync fork" button and a
# concurrent --push on another machine both produce. The fork already contains
# everything the push carried, so there is nothing for a human to reconcile and
# an immediate re-run would say current. That reports as current, not as STUCK.
#
# Exit status, so a scripted caller can tell a refusal from a success without
# parsing the output:
#   report-only  always 0. It was asked to say what it found and it did, whether
#                that was current, behind, a divergence, or a skip because a
#                remote could not be reached.
#   --push       0 only when the fork ends up level with upstream, counting the
#                no-op case where it already was. 1 whenever it was asked to
#                advance the fork and did not, whether the fork diverged, origin
#                refused the push, or either remote could not be reached.
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
  sed -n '2,88p' "$0" | sed 's/^# \{0,1\}//'
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

# The exit status every "could not do it" path shares. A report-only run was not
# asked to advance anything, so any skip is still a successful report. A --push
# run WAS asked to advance the fork, so every path that leaves the fork behind
# upstream - an unreachable remote, a missing ref, a divergence, a refused push -
# exits non-zero rather than looking like a success to a scripted caller.
REFUSED_EXIT=0
if [ "$PUSH" = yes ]; then
  REFUSED_EXIT=1
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
#
# Git SHELL-parses GIT_SSH_COMMAND, so the program word may legitimately be
# quoted or contain spaces. Splitting on whitespace would mangle such a value and
# leave the sweep reporting a network failure it caused itself, so the value is
# re-split the same way git does and requoted term by term. A value the shell
# cannot parse falls back to appending, which is weaker but never destructive.
prepend_ssh_batchmode() {
  local parts=() rebuilt i
  if ! eval "parts=($GIT_SSH_COMMAND)" 2>/dev/null || [ "${#parts[@]}" -eq 0 ]; then
    export GIT_SSH_COMMAND="$GIT_SSH_COMMAND -o BatchMode=yes"
    return 0
  fi
  rebuilt=$(printf '%q' "${parts[0]}")
  rebuilt="$rebuilt -o BatchMode=yes"
  for ((i = 1; i < ${#parts[@]}; i++)); do
    rebuilt="$rebuilt $(printf '%q' "${parts[i]}")"
  done
  export GIT_SSH_COMMAND="$rebuilt"
}

arm_noninteractive_git() {
  [ "$SWEEP" = yes ] || return 0
  export GIT_TERMINAL_PROMPT=0
  if [ -n "${GIT_SSH_COMMAND:-}" ]; then
    prepend_ssh_batchmode
  else
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes"
  fi
}

# An unattended run has no terminal to write to and its caller throws stderr away.
# A human run gets git's own diagnostic, which is the only place the real cause of
# an authentication or network failure is spelled out.
relay_git_error() {  # <text>
  [ "$SWEEP" = yes ] && return 0
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | sed 's/^/  /' >&2
}

# Report and move on: an absent upstream remote is the normal single-remote
# install, not a problem to escalate.
if ! git -C "$FM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "$LABEL: skipped: not a git repo"
  exit "$REFUSED_EXIT"
fi
if ! git -C "$FM_ROOT" remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  echo "$LABEL: skipped: no $UPSTREAM_REMOTE remote"
  exit "$REFUSED_EXIT"
fi
if ! git -C "$FM_ROOT" remote get-url origin >/dev/null 2>&1; then
  echo "$LABEL: skipped: no origin remote"
  exit "$REFUSED_EXIT"
fi

DEFAULT=$(default_branch "$FM_ROOT") || {
  echo "$LABEL: skipped: cannot determine default branch"
  exit "$REFUSED_EXIT"
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

# Only now, once a remote is actually about to be contacted. The cheap guards
# above cover every install this feature is inert for, and on those runs the
# operator's own GIT_SSH_COMMAND must never be evaluated at all - git itself
# would only have run it on a real connection, which never happens there.
arm_noninteractive_git

fetch_remote "$UPSTREAM_REMOTE" || exit "$REFUSED_EXIT"
# origin too, because the whole classification below is read off origin/<default>.
# A stale remote-tracking ref would under-report the fork's own commits and turn a
# genuine divergence into a clean "behind", which is precisely the case that must
# never be advanced automatically. Never classify against data we failed to refresh.
fetch_remote origin || exit "$REFUSED_EXIT"

UPSTREAM_REF="$UPSTREAM_REMOTE/$DEFAULT"
ORIGIN_REF="origin/$DEFAULT"
if ! UPSTREAM_REV=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$UPSTREAM_REF^{commit}"); then
  echo "$LABEL: skipped: $UPSTREAM_REF does not exist"
  exit "$REFUSED_EXIT"
fi
if ! ORIGIN_REV=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$ORIGIN_REF^{commit}"); then
  echo "$LABEL: skipped: $ORIGIN_REF does not exist"
  exit "$REFUSED_EXIT"
fi

# Ahead/behind of the FORK relative to upstream. "ahead" is the fork's own
# unlanded work, which is exactly what must never be rewritten automatically.
counts=$(git -C "$FM_ROOT" rev-list --left-right --count "$ORIGIN_REV...$UPSTREAM_REV" 2>/dev/null) || {
  echo "$LABEL: skipped: cannot compare $ORIGIN_REF with $UPSTREAM_REF"
  exit "$REFUSED_EXIT"
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
  exit "$REFUSED_EXIT"
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
  # Two very different failures wear the same non-zero exit, and git's own words
  # for them are translated, so the cause is established from the REFS instead.
  # Re-read origin and let its ref decide: still an ancestor of the commit we
  # tried to push means the push would have been a clean fast-forward, so nothing
  # about the branches is wrong and the refusal was about reaching or
  # authenticating to origin - the common case, since fetching a public fork is
  # anonymous while pushing to it needs a write token. Only a ref that positively
  # moved out from under us is STUCK. A ref that cannot be read at all is the
  # genuinely ambiguous case and stays loud, because an unclassifiable refusal
  # downgraded to a benign skip would silence the one signal this script raises.
  if ! git -C "$FM_ROOT" fetch origin --quiet >/dev/null 2>&1; then
    echo "$LABEL: skipped: cannot push to origin (network or credentials)"
  else
    NEW_ORIGIN_REV=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$ORIGIN_REF^{commit}" || true)
    if [ -z "$NEW_ORIGIN_REV" ]; then
      echo "$LABEL: STUCK: cannot read $ORIGIN_REF after origin refused the push - needs attention, see the error below"
    elif git -C "$FM_ROOT" merge-base --is-ancestor "$UPSTREAM_REV" "$NEW_ORIGIN_REV"; then
      # Origin already contains the commit we tried to push, so someone else got
      # there first - GitHub's "Sync fork" button, or a --push from another
      # machine. The fork is at or past where this run wanted it; there is
      # nothing to reconcile, so this is the goal reached, not a divergence.
      echo "$LABEL: current: $ORIGIN_REF already contains $UPSTREAM_REF; the fork was advanced elsewhere"
      exit 0
    elif ! git -C "$FM_ROOT" merge-base --is-ancestor "$NEW_ORIGIN_REV" "$UPSTREAM_REV"; then
      echo "$LABEL: STUCK: origin/$DEFAULT moved and no longer fast-forwards to $UPSTREAM_REF - needs attention, reconcile it by hand"
    else
      echo "$LABEL: skipped: cannot push to origin (network or credentials); $ORIGIN_REF would still fast-forward, so the branches are fine"
    fi
  fi
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
