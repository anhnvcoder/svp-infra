# shellcheck shell=bash
# Helpers of the session scripts of this directory, sourced by each of them. Those scripts reach the AWS account and
# the EKS cluster of a session: the learner runs them, from a terminal of the Mac (bash 3.2 is enough). Each takes
# --print as its first argument to show, in order, every command it would run, and then runs none: no aws, kubectl,
# helm, terraform, make, git or dig is called, nothing is read from the account and nothing is written.
#
# Every command that reaches AWS carries the profile and the region in the command itself (AWS_PROFILE=anhnv-sso ...
# --region ap-southeast-1), never in a shell variable the reader has to look up. Each step prints one line: ok, FAIL
# (and the script stops), note or skip. No secret value is ever printed or written to a file.

profile=anhnv-sso
region=ap-southeast-1

scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
infra_root=$(cd "$scripts_dir/../.." && pwd)
workspace=$(dirname "$infra_root")
# The clones of the code repository and of svp-gitops beside this one in the workspace.
# shellcheck disable=SC2034 # read by the scripts that source this file
backend_dir=${SVP_BACKEND_DIR:-$workspace/backend}
# shellcheck disable=SC2034 # read by the scripts that source this file
gitops_dir=${SVP_GITOPS_DIR:-$workspace/gitops}
# Seconds between two polls of a wait; the self-test sets 0.
poll=${SVP_SESSION_POLL:-10}

# File descriptor 3 is the terminal: --print writes the commands there, so a command whose output a script captures
# with $(...) still shows up.
exec 3>&1

print_only=
if [ "${1:-}" = --print ]; then
  print_only=1
fi

printing() { [ -n "$print_only" ]; }

# With --print nothing is checked, so no step reports a result.
ok() { printing || printf 'ok    %s\n' "$*"; }
note() { printing || printf 'note  %s\n' "$*"; }
skip() { printing || printf 'skip  %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*" >&2
  exit 1
}
step() { printf '== %s\n' "$*" >&3; }
# oneline: the lines of stdin joined by spaces.
oneline() { tr '\n' ' ' | sed 's/ *$//'; }

# show CMD...: the command as one would type it. Words of plain characters stay as they are; any other word is
# single-quoted, placeholders such as '<domain>' included, so that no line of --print is half a shell redirect.
show() {
  local line=+ a
  for a in "$@"; do
    case $a in
      *\'*) line="$line $(printf '%q' "$a")" ;;
      *[!A-Za-z0-9_./:=,@%+-]* | '') line="$line '$a'" ;;
      *) line="$line $a" ;;
    esac
  done
  printf '%s\n' "$line" >&3
}

# run_ [NAME=value ...] CMD ARGS...: shows the command with --print, runs it otherwise.
run_() {
  if printing; then
    show "$@"
    return 0
  fi
  env "$@"
}

aws_() { run_ "AWS_PROFILE=$profile" aws "$@" --region "$region"; }
# tf_ DIR ARGS...: terraform in root DIR of this repository.
tf_() {
  local dir=$1
  shift
  run_ "AWS_PROFILE=$profile" terraform -chdir="$dir" "$@"
}
# kc ARGS...: kubectl on the session's cluster, by the alias aws eks update-kubeconfig wrote (never the current
# context). Its credentials come from aws eks get-token, hence the profile.
kc() { run_ "AWS_PROFILE=$profile" kubectl --context "$context" "$@"; }
# make_ TARGET VARS...: a target of the code repository's Makefile (the eks-* targets).
make_() { run_ "AWS_PROFILE=$profile" make -C "$backend_dir" "$@"; }

# env_arg ENV: the environment a script works on. Only stg exists in this stage; its cluster, kubectl context and
# Terraform root carry its name.
env_arg() {
  case ${1:-} in
    stg) ;;
    *) fail "usage: $(basename "$0") [--print] stg (the only environment of this stage; got '${1:-}')" ;;
  esac
  env_name=$1
  # shellcheck disable=SC2034 # read by the scripts that source this file
  cluster=svp-$env_name
  context=svp-$env_name
  # shellcheck disable=SC2034 # read by the scripts that source this file
  root_dir=$infra_root/aws/envs/$env_name
}

# session_dir: the directory of this session's files, $SVP_SESSION_DIR, which must sit under .session/ of this
# repository (ignored by git: it holds the cluster values with the ACME email, and the measurements). With --print
# nothing is created.
session_dir() {
  if printing; then
    session=${SVP_SESSION_DIR:-$infra_root/.session/<time>}
    return 0
  fi
  [ -n "${SVP_SESSION_DIR:-}" ] ||
    fail "set SVP_SESSION_DIR first: export SVP_SESSION_DIR=\"$infra_root/.session/\$(date -u +%Y%m%dT%H%M%SZ)\""
  case $SVP_SESSION_DIR in
    "$infra_root"/.session/?*) ;;
    *) fail "SVP_SESSION_DIR=$SVP_SESSION_DIR is not under $infra_root/.session/ (the only directory git ignores for it)" ;;
  esac
  session=$SVP_SESSION_DIR
  (umask 077 && mkdir -p "$session") || fail "create $session"
}

# mark EVENT: one line of the session's timeline, $session/timeline.tsv: UTC time, epoch seconds, event.
mark() {
  if printing; then
    printf '  (timeline: %s)\n' "$1" >&3
    return 0
  fi
  local t
  t=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\t%s\t%s\n' "$t" "$(date +%s)" "$1" >>"$session/timeline.tsv"
  printf 'mark  %s %s\n' "$1" "$t"
}

# check_account: the account of profile anhnv-sso must be SVP_AWS_ACCOUNT_ID, which the learner exports in the
# terminal of the session after reading it on the SSO page (never in a file: the repository is public). Every script
# that reaches the account or the cluster runs it first, so a wrong profile stops before anything else; check-dns.sh
# alone does not, as it only reads one output of the bootstrap's state and changes nothing.
check_account() {
  local id account arn
  if ! printing; then
    [[ ${SVP_AWS_ACCOUNT_ID:-} =~ ^[0-9]{12}$ ]] ||
      fail "set SVP_AWS_ACCOUNT_ID to the 12 digits of the sandbox account, as the SSO page shows it (export SVP_AWS_ACCOUNT_ID=...; never in a file)"
  fi
  id=$(aws_ sts get-caller-identity --output json) ||
    fail "aws sts get-caller-identity with profile $profile (expired SSO session? AWS_PROFILE=$profile aws sso login)"
  printing && return 0
  account=$(jq -r '.Account // empty' <<<"$id")
  arn=$(jq -r '.Arn // empty' <<<"$id")
  [ "$account" = "$SVP_AWS_ACCOUNT_ID" ] ||
    fail "profile $profile is account '$account' ($arn), not SVP_AWS_ACCOUNT_ID $SVP_AWS_ACCOUNT_ID: stop here and check the profile"
  ok "account $account, $arn"
}

# wait_until DESCRIPTION SECONDS CMD...: polls CMD (a function of the script) every $poll seconds until it succeeds;
# returns 1 when SECONDS have gone by first. With --print, says what it waits for and runs CMD once, which shows the
# commands it polls with.
wait_until() {
  local desc=$1 limit=$2 start
  shift 2
  if printing; then
    printf '  (repeated every %s s, up to %s s, until %s)\n' "$poll" "$limit" "$desc" >&3
    "$@" || true
    return 0
  fi
  start=$(date +%s)
  until "$@"; do
    [ $(($(date +%s) - start)) -lt "$limit" ] || return 1
    sleep "$poll"
  done
}

# lab_zone: the lab's hosted zone, aws.<domain>: SVP_ZONE_NAME, or zone_name of aws/bootstrap/bootstrap.auto.tfvars
# (the uncommitted file of the bootstrap), read without Terraform so that it works when no state is left.
lab_zone() {
  if [ -n "${SVP_ZONE_NAME:-}" ]; then
    zone=$SVP_ZONE_NAME
  else
    local f=$infra_root/aws/bootstrap/bootstrap.auto.tfvars
    if [ ! -f "$f" ] && printing; then
      zone='<lab zone aws.domain>'
      return 0
    fi
    [ -f "$f" ] || fail "no $f: set SVP_ZONE_NAME=aws.<domain>, the lab zone of aws/bootstrap"
    zone=$(sed -n 's/^[[:space:]]*zone_name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n 1)
  fi
  [[ $zone =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] ||
    fail "lab zone '$zone' is not a DNS name such as aws.svp.example (SVP_ZONE_NAME or zone_name of aws/bootstrap/bootstrap.auto.tfvars)"
}
