#!/usr/bin/env bash
# First step of every AWS session: the account behind profile anhnv-sso must be the sandbox account the learner
# exported in SVP_AWS_ACCOUNT_ID (never written to a file). Prints the account and the ARN of the caller, for both
# sides to read; stops on any other account. Starts the session's timeline in $SVP_SESSION_DIR.
#
# Usage: aws/scripts/check-account.sh [--print]
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
case "$*" in '' | --print) ;; *) fail "usage: $(basename "$0") [--print]" ;; esac

session_dir
step "check-account.sh: the account of profile $profile"
check_account
if printing || [ ! -s "$session/timeline.tsv" ]; then
  mark session-start
fi
