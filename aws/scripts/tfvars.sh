#!/usr/bin/env bash
# The uncommitted files of the Terraform roots (*.auto.tfvars, aws/backend*.hcl), from the outputs of the roots that
# hold their values. Only the lines of a variable change: other lines, comments and order stay; a run with nothing to
# change leaves the file untouched. A file is written whole to a temporary file beside it (mode 600), then moved over.
# Nothing read is printed (ids, emails, domains, name servers): only names of variables, line counts and the result.

# Usage: aws/scripts/tfvars.sh [--print] example ROOT | init | delegation
#        aws/scripts/tfvars.sh [--print] backend mgmt|stg|prd
#        aws/scripts/tfvars.sh [--print] groups|env stg|prd
#        aws/scripts/tfvars.sh [--print] bump stg|prd msk|valkey
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
me=$(basename "$0")
usage="usage: $me [--print] example ROOT | backend $(env_names) | init | groups $(env_names session) | env $(env_names session) | delegation | bump $(env_names session) msk|valkey"
[ $# -ge 1 ] || fail "$usage"
cd "$infra_root"

# The roots of the management account and the -backend-config each one takes, as in aws/bootstrap/README.md.
init_roots='aws/bootstrap ../backend.hcl
aws/org ../backend.hcl
aws/log-archive ../backend.hcl
aws/security ../backend.hcl
aws/baseline ../backend.hcl
aws/backup ../backend.hcl
github ../aws/backend.hcl'
# Variables that root env no longer declares: Terraform only warns about them, so a file keeps them unless removed.
env_undeclared='eks_public_access_cidrs acme_email grafana_workspace_id'
# The root whose zone the stg zone is delegated from, and the root of that zone.
parent_env=prd child_env=stg

# A variable of a tfvars file, at the top level of the file, on its line and the lines of its value when that one spans
# several ({...}, [...]). Modes: get prints the text after "=" of its first line; set replaces that text, or appends
# "NAME = VALUE"; del drops it. Name and value come in TFV_NAME, TFV_VALUE (never in the arguments of a process).
# Exits 3 when the variable is set twice: Terraform refuses such a file.
# shellcheck disable=SC2016 # awk code
tfvars_awk='
function depth(s,   a, b) {
  gsub(/"([^"\\]|\\.)*"/, "\"\"", s)
  sub(/(#|\/\/).*$/, "", s)
  a = s; b = s
  return gsub(/[[{(]/, "", a) - gsub(/[]})]/, "", b)
}
BEGIN { mode = ENVIRON["TFV_MODE"]; name = ENVIRON["TFV_NAME"]; value = ENVIRON["TFV_VALUE"]; d = 0; inv = 0; n = 0 }
inv { d += depth($0); if (d <= 0) { inv = 0; d = 0 }; next }
d == 0 && match($0, "^" name "[ \t]*=[ \t]*") {
  n++
  rest = substr($0, RLENGTH + 1)
  if (n == 1 && mode == "get") print rest
  if (n == 1 && mode == "set") print substr($0, 1, RLENGTH) value
  if (depth(rest) > 0) { inv = 1; d = depth(rest) }
  next
}
{ if (mode != "get") print; d += depth($0) }
END {
  if (n > 1) { print name " is set " n " times" | "cat 1>&2"; exit 3 }
  if (mode == "set" && n == 0) print name " = " value
}'

# tfv MODE NAME [VALUE]: tfvars_awk on stdin.
tfv() { TFV_MODE=$1 TFV_NAME=$2 TFV_VALUE=${3:-} awk "$tfvars_awk"; }

# get_var FILE NAME: the text after "=" of the line of NAME in FILE; nothing when FILE or the line is missing.
get_var() {
  [ -f "$1" ] || return 0
  tfv get "$2" <"$1" || fail "$1: $2 is set more than once (Terraform refuses the file): keep one line"
}

# new_file FILE: tmp, a new temporary file beside FILE (the same directory, so that mv replaces FILE at once), mode 600,
# removed on exit unless moved.
tmp_files=
trap 'for t in $tmp_files; do rm -f "$t"; done' EXIT
new_file() {
  tmp=$(umask 077 && mktemp "$(dirname "$1")/.tfvars.XXXXXX") || fail "create a temporary file beside $1"
  tmp_files="$tmp_files $tmp"
}

# commit FILE TMP WHAT: FILE takes the content of TMP, mode 600, unless it holds it already.
commit() {
  if [ -f "$1" ] && cmp -s "$1" "$2"; then
    rm -f "$2"
    ok "$1: $3 already as written, file unchanged"
    return 0
  fi
  { chmod 600 "$2" && mv "$2" "$1"; } || fail "move the new $1 into place (the old file is unchanged)"
  ok "$1: $3 written ($(wc -l <"$1" | tr -d ' ') lines, mode 600)"
}

# edit FILE WHAT CMD...: FILE (empty when missing) through CMD, a pipeline of tfv calls read from stdin, to a temporary
# file, then commit. A failed CMD writes nothing.
edit() {
  local f=$1 what=$2 t
  shift 2
  new_file "$f"
  t=$tmp
  if [ -f "$f" ]; then "$@" <"$f" >"$t"; else "$@" </dev/null >"$t"; fi ||
    fail "$f: a variable is set more than once (Terraform refuses the file): keep one line of it; file unchanged"
  commit "$f" "$t" "$what"
}

# output ROOT NAME [json]: output NAME of ROOT (-raw, or -json), with the profile of the current row; fails when the
# output is missing or empty.
output() {
  local v
  if [ "${3:-}" = json ]; then
    v=$(tf_ "$1" output -json "$2") || fail "terraform output $2 of $1 with profile $profile (root not applied, or not initialised in this checkout?)"
  else
    v=$(tf_ "$1" output -raw "$2") || fail "terraform output $2 of $1 with profile $profile (root not applied, or not initialised in this checkout?)"
  fi
  printing && return 0
  [ -n "$v" ] || fail "output $2 of $1 is empty: nothing written"
  printf '%s\n' "$v"
}

# member ENV: ENV has the roots of a session, so it is a member account with a baseline under aws/accounts/<env>; the
# management account has none (its backend comes from aws/bootstrap).
member() {
  case "|$(env_names session)|" in
    *"|$1|"*) return 0 ;;
    *) return 1 ;;
  esac
}

need_file() {
  printing || [ -f "$1" ] || fail "no $1: $2"
}

# example ROOT: copies the *.auto.tfvars.example of ROOT (aws/org, aws/envs/stg, github...) to its tfvars file when that
# one is missing, never over it; then lists the variables whose value still holds a placeholder <...>.
cmd_example() {
  local root=${1:-} ex target name
  [ -n "$root" ] || fail "$usage"
  root=${root%/}
  case "/$root/" in
    */../* | */./* | //*) fail "ROOT is a directory of this repository written from its top, such as aws/org (got '$root')" ;;
  esac
  [ -d "$root" ] || fail "no directory $root in this repository"
  set -- "$root"/*.auto.tfvars.example
  [ $# -eq 1 ] && [ -f "$1" ] || fail "$root has no single *.auto.tfvars.example"
  ex=$1
  name=$(basename "${ex%.example}")
  # The examples of the session roots are named example.auto.tfvars.example: the file is <env>.auto.tfvars.
  [ "$name" != example.auto.tfvars ] || name=$(basename "$root").auto.tfvars
  target=$root/$name
  if printing; then
    printf '  (copy %s to %s, mode 600, when %s is missing; list its placeholders <...>)\n' "$ex" "$target" "$target" >&3
    return 0
  fi
  if [ -f "$target" ]; then
    ok "$target exists: left as it is"
  else
    new_file "$target"
    cp "$ex" "$tmp" || fail "copy $ex"
    commit "$target" "$tmp" "copy of $(basename "$ex")"
    note "$target holds the example's values: replace each with yours (README.md of $root)"
  fi
  local lines
  # One line per value that still holds <...>: line number, then the variable (parent.key inside a map or object).
  # shellcheck disable=SC2016 # awk code
  lines=$(awk '
    function depth(s,   a, b) {
      gsub(/"([^"\\]|\\.)*"/, "\"\"", s); sub(/(#|\/\/).*$/, "", s); a = s; b = s
      return gsub(/[[{(]/, "", a) - gsub(/[]})]/, "", b)
    }
    /^[ \t]*(#|\/\/)/ { next }
    {
      k = $0; sub(/^[ \t]*/, "", k); sub(/[ \t]*=.*/, "", k); gsub(/"/, "", k)
      if (d == 0 && $0 ~ /=/) { top = k; key = k } else if ($0 ~ /=/) key = top "." k
      v = $0; sub(/^[^=]*=/, "", v)
      if (v ~ /<[^>]*>/) print FNR " " key
      d += depth($0)
    }' "$target")
  if [ -z "$lines" ]; then
    ok "$target: no placeholder <...> left"
    return 0
  fi
  while read -r n key; do
    note "$target:$n $key still holds a placeholder <...>"
  done <<<"$lines"
}

# backend ENV: aws/backend.hcl from output backend_hcl of aws/bootstrap (mgmt), aws/backend-<env>.hcl from that of
# aws/accounts/<env>.
cmd_backend() {
  local src target out
  env_arg "${1:-}" any
  if member "$env_name"; then
    src=aws/accounts/$env_name target=aws/backend-$env_name.hcl
  else
    src=aws/bootstrap target=aws/backend.hcl
  fi
  check_account
  out=$(output "$src" backend_hcl)
  if printing; then
    printf '  (output written to %s, mode 600)\n' "$target" >&3
    return 0
  fi
  grep -q '^[[:space:]]*bucket[[:space:]]*=' <<<"$out" ||
    fail "output backend_hcl of $src has no bucket: not a backend configuration, nothing written"
  new_file "$target"
  printf '%s\n' "$out" >"$tmp"
  commit "$target" "$tmp" "output backend_hcl of $src"
}

# init: terraform init -reconfigure of each root of the management account with aws/backend.hcl.
cmd_init() {
  local root cfg
  env_arg mgmt any
  need_file aws/backend.hcl "$me backend mgmt first"
  check_account
  while read -r root cfg; do
    tf_ "$root" init -input=false -reconfigure "-backend-config=$cfg" >&2 ||
      fail "terraform init -reconfigure of $root (the roots before it are done; run $me init again once fixed)"
    ok "terraform init -reconfigure of $root with $cfg"
  done <<<"$init_roots"
}

# groups ENV: platform_admin_group_id, platform_viewer_group_id of aws/accounts/<env>/<env>.auto.tfvars from aws/org.
cmd_groups() {
  local f admin viewer g
  env_arg "${1:-}"
  f=aws/accounts/$env_name/$env_name.auto.tfvars
  need_file "$f" "$me example aws/accounts/$env_name first"
  env_arg mgmt any
  check_account
  admin=$(output aws/org platform_admin_group_id)
  viewer=$(output aws/org platform_viewer_group_id)
  if printing; then
    printf '  (platform_admin_group_id, platform_viewer_group_id set in %s, mode 600)\n' "$f" >&3
    return 0
  fi
  for g in "$admin" "$viewer"; do
    [[ $g =~ ^[A-Za-z0-9-]+$ ]] || fail "an output platform_*_group_id of aws/org is not a group id: nothing written"
  done
  edit "$f" "platform_admin_group_id, platform_viewer_group_id from aws/org" \
    pipe "set platform_admin_group_id \"$admin\"" "set platform_viewer_group_id \"$viewer\""
}

# pipe STEP...: tfv MODE NAME VALUE for each STEP ("MODE NAME VALUE", the value being the rest of the step), chained.
pipe() {
  [ $# -gt 0 ] || {
    cat
    return
  }
  local step=$1 mode name
  shift
  mode=${step%% *}
  step=${step#* }
  name=${step%% *}
  step=${step#"$name"}
  step=${step# }
  tfv "$mode" "$name" "$step" | pipe "$@"
}

# ask NAME FILE CHECK HINT: a value of NAME read from the terminal, CHECK a regular expression it must match; stops when
# stdin is not a terminal. The value is not repeated in any message.
ask() {
  local v
  [ -t 0 ] || fail "$2 has no $1 and stdin is not a terminal: run $me env $env_name in a terminal, or add the line by hand; nothing written"
  printf '%s for %s (%s): ' "$1" "$2" "$4" >&2
  IFS= read -r v || fail "no $1 read: nothing written"
  [[ $v =~ $3 ]] || fail "that $1 is not $4: nothing written"
  printf '%s\n' "$v"
}

# env ENV: aws/envs/<env>/<env>.auto.tfvars: hosted_zone_id from output zone_id of aws/accounts/<env>; domain and
# alarm_email kept, asked on the terminal when missing; the lines of variables the root no longer declares removed.
cmd_env() {
  local f domain email zone steps=() removed='' v
  env_arg "${1:-}"
  f=aws/envs/$env_name/$env_name.auto.tfvars
  if printing; then
    check_account
    output "aws/accounts/$env_name" zone_id
    printf '  (%s: hosted_zone_id from that output; domain, alarm_email kept or asked on the terminal; lines of %s removed; mode 600)\n' \
      "$f" "$env_undeclared" >&3
    return 0
  fi
  domain=$(get_var "$f" domain) || exit 1
  email=$(get_var "$f" alarm_email) || exit 1
  [ -n "$domain" ] || {
    domain=$(ask domain "$f" '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' "the name of the hosted zone of $env_name, such as stg.aws.svp.example") || exit 1
    steps+=("set domain \"$domain\"")
  }
  [ -n "$email" ] || {
    email=$(ask alarm_email "$f" '^[^@[:space:]"]+@[^@[:space:]"]+\.[^@[:space:]"]+$' "the inbox of the alarms, an email address") || exit 1
    steps+=("set alarm_email \"$email\"")
  }
  check_account
  zone=$(output "aws/accounts/$env_name" zone_id)
  [[ $zone =~ ^Z[A-Z0-9]+$ ]] || fail "output zone_id of aws/accounts/$env_name is not a hosted zone id: nothing written"
  for v in $env_undeclared; do
    if [ -f "$f" ] && grep -q -E "^${v}[[:space:]]*=" "$f"; then
      steps+=("del $v")
      removed="$removed $v"
    fi
  done
  edit "$f" "hosted_zone_id from aws/accounts/$env_name, domain, alarm_email${removed:+; removed:$removed}" \
    pipe "set hosted_zone_id \"$zone\"" ${steps[@]+"${steps[@]}"}
  ok "$f: $(grep -c -E '^(hosted_zone_id|domain|alarm_email)[[:space:]]*=' "$f") of hosted_zone_id, domain, alarm_email"
}

# delegation: delegated_subdomains of aws/accounts/prd/prd.auto.tfvars, the stg zone with the name servers of
# aws/accounts/stg.
cmd_delegation() {
  local f ns zone n value
  f=aws/accounts/$parent_env/$parent_env.auto.tfvars
  need_file "$f" "$me example aws/accounts/$parent_env first"
  env_arg "$child_env"
  env_zone
  check_account
  ns=$(output "aws/accounts/$child_env" name_servers json)
  if printing; then
    printf '  (delegated_subdomains of %s set to the zone of %s and those name servers, mode 600)\n' "$f" "$child_env" >&3
    return 0
  fi
  ns=$(jq -r '.[]' <<<"$ns" 2>/dev/null) || fail "output name_servers of aws/accounts/$child_env is not a JSON list: nothing written"
  n=$(grep -c . <<<"$ns" || true)
  [ "$n" -eq 4 ] || fail "output name_servers of aws/accounts/$child_env has $n names, not 4: nothing written"
  grep -q -v -E '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' <<<"$ns" &&
    fail "output name_servers of aws/accounts/$child_env holds a name that is not a DNS name: nothing written"
  value=$(printf '{\n  "%s" = [' "$zone"
    printf '%s\n' "$ns" | awk '{ printf "%s\"%s\"", (NR > 1 ? ", " : ""), $0 }'
    printf ']\n}')
  edit "$f" "delegated_subdomains: zone of $child_env, 4 name servers" pipe "set delegated_subdomains $value"
}

# bump ENV msk|valkey: raises <msk|valkey>_password_version of aws/envs/<env>/<env>.auto.tfvars by one (from the
# default of the variable when the file has no line for it).
cmd_bump() {
  local f var cur
  env_arg "${1:-}"
  case ${2:-} in
    msk | valkey) var=$2_password_version ;;
    *) fail "$usage" ;;
  esac
  f=aws/envs/$env_name/$env_name.auto.tfvars
  if printing; then
    printf '  (%s of %s raised by one, mode 600)\n' "$var" "$f" >&3
    return 0
  fi
  need_file "$f" "$me env $env_name first"
  cur=$(get_var "$f" "$var") || exit 1
  cur=${cur%%#*}
  cur=$(tr -d '[:space:]' <<<"$cur")
  if [ -z "$cur" ]; then
    # No line: the version in use is the default of the variable.
    cur=$(awk -v v="$var" '$0 ~ "^variable \"" v "\"" { b = 1 } b && /^[ \t]*default[ \t]*=/ { sub(/.*=[ \t]*/, ""); print; exit }
      b && /^}/ { exit }' "$env_root/variables.tf")
    [[ $cur =~ ^[0-9]+$ ]] || fail "variable $var of aws/envs/$env_name has no whole-number default"
  fi
  [[ $cur =~ ^[0-9]+$ ]] || fail "$var of $f is not a whole number: fix it by hand; file unchanged"
  edit "$f" "$var from $cur to $((cur + 1))" pipe "set $var $((cur + 1))"
}

cmd=$1
shift
case "$cmd $#" in
  'example 1') step "tfvars.sh: example $1"; cmd_example "$1" ;;
  'backend 1') step "tfvars.sh: backend $1"; cmd_backend "$1" ;;
  'init 0') step "tfvars.sh: init"; cmd_init ;;
  'groups 1') step "tfvars.sh: groups $1"; cmd_groups "$1" ;;
  'env 1') step "tfvars.sh: env $1"; cmd_env "$1" ;;
  'delegation 0') step "tfvars.sh: delegation"; cmd_delegation ;;
  'bump 2') step "tfvars.sh: bump $1 $2"; cmd_bump "$1" "$2" ;;
  *) fail "$usage" ;;
esac
