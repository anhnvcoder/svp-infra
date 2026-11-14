# shellcheck shell=bash
# Helpers of the session scripts of this directory, sourced by each of them; they run from a terminal of the Mac (bash
# 3.2). --print as the first argument of each shows, in order, every command it would run, and then runs none. Every
# command that reaches AWS carries the profile and the region; no secret value is printed or written to a file.
# Design notes: README.md.

region=ap-southeast-1
# CloudFront's web ACLs (scope CLOUDFRONT), certificates and log delivery sources, and the Pricing Plan Manager
# (CloudFront flat-rate plans) live in us-east-1 whatever the region of the distribution.
global_region=us-east-1

# The environments, one line each: the only place where they differ; no script branches on an environment's name.
# Fields, read by env_arg: name, AWS profile, variable with the 12 digits of the account (exported, never in a file),
# hosted zone 1/- (env_zone), Stack tags kept between sessions (sweep.sh), local port of the SSM tunnel to a private API
# endpoint, file of aws/envs/<name> that lifts the protections a destroy needs, k6 ladder 1/-, session roots 1/-.
env_table='mgmt anhnv-sso SVP_AWS_MGMT_ACCOUNT_ID - bootstrap,org,security-baseline,security - - - -
stg anhnv-stg SVP_AWS_STG_ACCOUNT_ID 1 baseline,security-baseline 6444 - 1 1
prd anhnv-prd SVP_AWS_PRD_ACCOUNT_ID 1 baseline,security-baseline 6443 teardown.tfvars - 1'

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
# aws_global_ ARGS...: aws in the region of CloudFront's web ACLs and of the Pricing Plan Manager.
aws_global_() { run_ "AWS_PROFILE=$profile" aws "$@" --region "$global_region"; }
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

# env_names FIELD: the names of the environments whose FIELD (session) is set, or of all of them without FIELD.
env_names() {
  awk -v f="${1:-}" 'f == "" || $9 == "1" { printf "%s%s", sep, $1; sep = "|" }' <<<"$env_table"
}

# env_arg ENV [any]: the environment a script works on, and the fields of its line of env_table. Without any, only an
# environment with the session's roots (stg, prd); with it, mgmt too.
env_arg() {
  local line names
  if [ "${2:-}" = any ]; then names=$(env_names); else names=$(env_names session); fi
  case "|$names|" in
    *"|${1:-}|"*) [ -n "${1:-}" ] ;;
    *) false ;;
  esac || fail "usage: $(basename "$0") [--print] $names ... (got '${1:-}')"
  line=$(awk -v e="$1" '$1 == e' <<<"$env_table")
  # shellcheck disable=SC2034 # read by the scripts that source this file
  read -r env_name profile account_var has_zone kept_stacks tunnel_port teardown ladder _ <<<"$line"
  [ "$has_zone" != - ] || has_zone=
  [ "$tunnel_port" != - ] || tunnel_port=
  [ "$teardown" != - ] || teardown=
  [ "$ladder" != - ] || ladder=
  # shellcheck disable=SC2034 # read by the scripts that source this file
  cluster=svp-$env_name
  context=svp-$env_name
  # shellcheck disable=SC2034 # read by the scripts that source this file
  env_root=$infra_root/aws/envs/$env_name
  # shellcheck disable=SC2034 # read by the scripts that source this file
  gitops_root=$infra_root/aws/gitops/$env_name
}

# session_dir: the directory of this session's files, $SVP_SESSION_DIR, which must sit under .session/ of this
# repository (ignored by git: its cluster values and plan texts name the real domain). With --print nothing is
# created.
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

# check_account: the account of the environment's profile must be the one in its account variable
# (SVP_AWS_<ENV>_ACCOUNT_ID), exported in the session's terminal (never in a committed file: the repository is public).
# Every script that reaches the account or the cluster runs it first, so a wrong profile stops before anything else;
# check-dns.sh alone does not: it only reads one output of the baseline's state and changes nothing.
check_account() {
  local id account arn want
  want=${!account_var:-}
  if ! printing; then
    [[ $want =~ ^[0-9]{12}$ ]] ||
      fail "set $account_var to the 12 digits of the $env_name account, as the SSO page shows it (export $account_var=...; never in a committed file)"
  fi
  id=$(aws_ sts get-caller-identity --output json) ||
    fail "aws sts get-caller-identity with profile $profile (expired SSO session? AWS_PROFILE=$profile aws sso login)"
  printing && return 0
  account=$(jq -r '.Account // empty' <<<"$id")
  arn=$(jq -r '.Arn // empty' <<<"$id")
  [ "$account" = "$want" ] ||
    fail "profile $profile is account '$account' ($arn), not $account_var $want of $env_name: stop here and check the profile"
  ok "account $account of $env_name, $arn"
}

# kubeconfig: the context $context of the session's cluster in the kubeconfig, under the alias the make targets of the
# code repository take (CONTEXT=svp-<env>). For an environment whose API endpoint is private (tunnel), the cluster's
# entry then points at the local end of the tunnel, with the endpoint's host as TLS server name, as output
# kubeconfig_command of aws/envs/<env> does. Neither command reaches the API.
kubeconfig() {
  local out arn host
  aws_ eks update-kubeconfig --name "$cluster" --alias "$context" >/dev/null || return 1
  [ -n "$tunnel_port" ] || return 0
  out=$(aws_ eks describe-cluster --name "$cluster" --output json) || return 1
  if printing; then
    arn='<cluster.arn>' host='<host of cluster.endpoint>'
  else
    arn=$(jq -r '.cluster.arn // empty' <<<"$out")
    host=$(jq -r '.cluster.endpoint // empty' <<<"$out")
    host=${host#https://}
    host=${host%%/*}
    [ -n "$arn" ] && [ -n "$host" ] || return 1
  fi
  run_ kubectl config set-cluster "$arn" --server="https://127.0.0.1:$tunnel_port" --tls-server-name="$host" >/dev/null
}

# need_tunnel: for an environment whose API endpoint is private, the SSM tunnel must be open on 127.0.0.1:<tunnel>
# before any command to the API; it runs in a terminal of its own (output api_tunnel_command of aws/envs/<env>).
# Nothing to check for a public endpoint.
need_tunnel() {
  [ -n "$tunnel_port" ] || return 0
  run_ nc -z -w 3 127.0.0.1 "$tunnel_port" >/dev/null 2>&1 ||
    fail "no tunnel on 127.0.0.1:$tunnel_port to the API of $cluster: in a terminal of its own, from the root of this repository, run eval \"\$(AWS_PROFILE=$profile terraform -chdir=aws/envs/$env_name output -raw api_tunnel_command)\" and keep it running; then run this again"
  ok "tunnel to the API of $cluster open on 127.0.0.1:$tunnel_port"
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

# env_zone: the hosted zone of the environment's account, in zone: zone_name of aws/accounts/<env>/<env>.auto.tfvars
# (the uncommitted file of the baseline that made the zone), read without Terraform so that it works when no state is
# left. Empty for an account without a hosted zone (zone - in env_table).
env_zone() {
  zone=
  [ -n "$has_zone" ] || return 0
  local f=$infra_root/aws/accounts/$env_name/$env_name.auto.tfvars
  if [ ! -f "$f" ] && printing; then
    zone="<zone_name of aws/accounts/$env_name>"
    return 0
  fi
  [ -f "$f" ] || fail "no $f: the file of the baseline aws/accounts/$env_name, whose zone_name is the hosted zone of $env_name"
  zone=$(sed -n 's/^[[:space:]]*zone_name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n 1)
  [[ $zone =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] ||
    fail "zone_name '$zone' of $f is not a DNS name such as aws.svp.example"
}

# The paid features of each account, the file the Terraform roots read through modules/paid-features; each flag with
# the values its validation allows, the first being the one of an absent key.
paid_features_file=$infra_root/aws/paid-features.json
paid_flags='managed_grafana always,session
inspector_ecr always,off
security_hub always,off
config_recording always,off'

# paid_feature ACCOUNT FLAG: the value of FLAG for ACCOUNT (a key of the file: mgmt, log-archive, ..., stg, prd).
paid_feature() {
  local values value
  values=$(awk -v f="$2" '$1 == f { print $2 }' <<<"$paid_flags")
  [ -n "$values" ] || fail "paid feature '$2' is not one of $(awk '{ print $1 }' <<<"$paid_flags" | oneline)"
  value=$(jq -r --arg a "$1" --arg f "$2" '.[$a][$f] // empty' "$paid_features_file") ||
    fail "read $paid_features_file"
  value=${value:-${values%%,*}}
  case ",$values," in
    *",$value,"*) printf '%s\n' "$value" ;;
    *) fail "$1.$2 of $paid_features_file is '$value', not one of $values" ;;
  esac
}

# session_features ENV: the flags of ENV whose value is session, one per line; nothing when it has none.
session_features() {
  local flag value
  while read -r flag _; do
    value=$(paid_feature "$1" "$flag") || return 1
    [ "$value" != session ] || printf '%s\n' "$flag"
  done <<<"$paid_flags"
}
