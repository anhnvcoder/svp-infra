#!/usr/bin/env bash
# terraform plan of a pull request for workflow plan.yml. gate decides which envs plan; plan ENV plans the roots of
# one env with the job's OIDC token and the read-only role svp-ci-terraform-plan, and writes a masked summary
# (counts and addresses, never attribute values) to $RUNNER_TEMP/plan-summary/<env>. Design notes: docs/reference/ci.md.

# plan refuses to run outside GitHub Actions: a dev machine never reaches an account with it. Nothing is written but
# below $RUNNER_TEMP; the plan text is never printed or kept, terraform's stderr is printed masked and only on failure.

# Usage: ci/terraform-plan.sh gate
#        ci/terraform-plan.sh plan stg|prd
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
region=ap-southeast-1
# Workflow commands and notices go to the step's log even while stdout feeds a pipe.
exec 3>&1

fail() {
  printf '::error::%s\n' "$1" >&3
  if [ -n "${summary:-}" ] && [ -f "$summary" ]; then printf '\n**Failed:** %s\n' "$1" >>"$summary"; fi
  exit 1
}
notice() {
  printf '::notice::%s\n' "$1" >&3
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf -- '- %s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
}

# The roots CI never plans, and why: a changed file below one of them alone does not start a plan.
skipped_root() {
  local root reason
  case $1 in
    aws/bootstrap/* | aws/org/*) root=aws/$(cut -d/ -f2 <<<"$1") reason='management account: no CI role there' ;;
    aws/log-archive/* | aws/security/* | aws/baseline/* | aws/backup/*)
      root=aws/$(cut -d/ -f2 <<<"$1") reason='runs from the management account through OrganizationAccountAccessRole' ;;
    aws/gitops/*/*) root=aws/gitops/$(cut -d/ -f3 <<<"$1") reason='the EKS API is reachable through the tunnel alone' ;;
    github/*) root=github reason='needs an admin token of GitHub' ;;
    *) return 1 ;;
  esac
  printf '%s\t%s\n' "$root" "$reason"
}

# The files a change of which can change a plan: the paths of the workflow's trigger.
plan_path() {
  case $1 in
    aws/* | ci/* | Makefile | .github/workflows/plan.yml) return 0 ;;
    *) return 1 ;;
  esac
}

gate() {
  local envs files listed count f line plans=false roots=''
  : "${GITHUB_OUTPUT:?}" "${REPO:?}" "${PR:?}" "${CHANGED:?}"
  envs=$(jq -c 'if type == "array" and all(.[]; . == "stg" or . == "prd") then unique else error("") end' \
    <<<"${PLAN_ENVS:-[]}" 2>/dev/null) ||
    fail "variable SVP_TF_PLAN_ENVS is not a JSON array of stg and prd: ${PLAN_ENVS:-}"
  if [ "$envs" = '[]' ]; then
    notice "terraform plan is off: variable SVP_TF_PLAN_ENVS is empty"
  elif [ "${HEAD_REPO:-}" != "$REPO" ]; then
    notice "pull request from the fork ${HEAD_REPO:-}: no plan, a fork's code never gets the plan role"
    envs='[]'
  else
    # Both names of a renamed file. A list shorter than the pull request's count of changed files is incomplete
    # (the API lists at most 3000), and then the plan runs.
    listed=$(gh api --paginate "repos/$REPO/pulls/$PR/files" --jq '.[] | [.filename, (.previous_filename // "")] | @tsv') ||
      fail "gh api repos/$REPO/pulls/$PR/files"
    count=$(printf '%s\n' "$listed" | grep -c . || true)
    if [ "$count" -ne "$CHANGED" ]; then
      notice "the API listed $count of the $CHANGED changed files: the plan runs"
      plans=true
    fi
    files=$(printf '%s\n' "$listed" | tr '\t' '\n' | grep -v '^$' || true)
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if line=$(skipped_root "$f"); then
        roots=$(printf '%s\n%s' "$roots" "$line")
      elif plan_path "$f"; then
        plans=true
      fi
    done <<<"$files"
    while IFS=$'\t' read -r f line; do
      [ -z "$f" ] || notice "$f is not planned in CI: $line"
    done < <(printf '%s\n' "$roots" | sort -u)
    if [ "$plans" = false ]; then
      notice "the pull request changes no root CI plans"
      envs='[]'
    fi
  fi
  echo "envs=$envs" >>"$GITHUB_OUTPUT"
  echo "envs=$envs"
}

# The values masked in the log (add-mask) and in the summary: every string and number of a tfvars file on stdin,
# one per line. Strings and end-of-line comments are one scan, left to right, so a quote in a comment hides no value.
# Refuses a heredoc, a block comment or an unterminated string, whose values these patterns would not see.
tfvars_values() {
  jq -Rrs '
    def token: "\"(?:[^\"\\\\]|\\\\.)*\"|(?:#|//)[^\n]*";
    split("\n") | map(select(test("^\\s*(#|//)") | not))
    | if any(.[]; test("<<|/\\*")) then error("heredoc or block comment") else join("\n") end
    | ([scan(token) | select(startswith("\"")) | .[1:-1] | ., (("\"" + . + "\"") | fromjson? // empty)]) as $strings
    | gsub(token; " ") | if test("\"") then error("unterminated string") else . end
    | gsub("[A-Za-z_][A-Za-z0-9_-]*"; " ")
    | ($strings + [scan("[0-9]+(?:\\.[0-9]+)?")])[] | select(length > 0)'
}

# add_mask VALUE...: masks each value in the log from here on and adds it to the masks of the summary and of stderr.
add_mask() {
  local v
  for v in "$@"; do
    printf '::add-mask::%s\n' "${v//%/%25}" >&3
    printf '%s\n' "$v" >>"$masks"
  done
}

# mask: stdin with every masked value replaced by ***, longest first.
mask() {
  jq -Rrs --rawfile m "$masks" \
    'reduce ($m | split("\n") | map(select(length > 0)) | unique | sort_by(-length))[] as $v (.; split($v) | join("***"))'
}

# new_token: a fresh OIDC token of the job in $secret/token, rewritten in place (the container mounts it): a token
# lives five minutes, and the SDK reads the file again at each assume.
new_token() {
  local token
  token=$(curl -sSf -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r '.value // empty') || token=
  [ -n "$token" ] || fail "no OIDC token from ACTIONS_ID_TOKEN_REQUEST_URL (the job needs permission id-token: write)"
  add_mask "$token"
  (umask 077 && printf '%s' "$token" >"$secret/token") || fail "write the OIDC token below $secret"
}

# tf ROOT DATA ARGS...: terraform ARGS in ROOT, working data in DATA, with a fresh token. stdout is the caller's;
# stderr is kept and printed masked when terraform fails (plan's exit code 2 means changes, not a failure).
tf() {
  local root=$1 data=$2 rc=0
  shift 2
  new_token
  env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e CHECKPOINT_DISABLE=1 \
    -e TF_IN_AUTOMATION=1 -e TF_DATA_DIR=/tfdata -e AWS_ROLE_ARN -e AWS_WEB_IDENTITY_TOKEN_FILE=/run/svp/token \
    -e AWS_ROLE_SESSION_NAME -e AWS_REGION=$region -e TF_VAR_account_id -e TF_VAR_backup_account_id \
    -e TF_VAR_log_archive_account_id -v "$repo:/src:ro" -v "$data:/tfdata" -v "$secret:/run/svp:ro" -w "/src/$root" \
    "$TERRAFORM_IMAGE" "$@" 2>"$work/stderr" || rc=$?
  if [ "$rc" -ne 0 ] && ! { [ "$rc" -eq 2 ] && [ "$1" = plan ]; }; then
    mask <"$work/stderr" >&2
  fi
  return "$rc"
}

# init ROOT KEY DATA: the S3 backend of the env's state bucket, the root's lock file as it is.
init() {
  tf "$1" "$3" init -input=false -no-color -lockfile=readonly "-backend-config=bucket=$bucket" \
    "-backend-config=key=$2" "-backend-config=region=$region" >/dev/null || fail "terraform init of $1"
}

# plan_root ROOT DATA HEADING ARGS...: plan without lock or input, then the summary section of its show -json.
plan_root() {
  local root=$1 data=$2 heading=$3 rc=0 sections
  shift 3
  tf "$root" "$data" plan -input=false -lock=false -no-color -detailed-exitcode "$@" -out=/tfdata/plan.tfplan \
    >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || fail "terraform plan of $root"
  sections=$(tf "$root" "$data" show -json -no-color /tfdata/plan.tfplan | summarize "$root" "$heading") ||
    fail "terraform show -json of $root"
  jq -r .full <<<"$sections" >>"$summary"
  jq -r .short <<<"$sections" >>"$short"
}

# summarize ROOT HEADING: the plan JSON on stdin as {full, short} Markdown: counts, then each change's address and
# action; short has the counts alone. Addresses are masked (a for_each key may be a domain or an account id).
summarize() {
  jq -c --arg root "$1" --arg heading "$2" --rawfile m "$masks" '
    def mask: reduce ($m | split("\n") | map(select(length > 0)) | unique | sort_by(-length))[] as $v
      (.; split($v) | join("***"));
    def action: if . == ["create"] then "create" elif . == ["update"] then "update" elif . == ["delete"] then "delete"
      elif sort == ["create", "delete"] then "replace" elif . == ["forget"] then "forget" else empty end;
    [.resource_changes[]? | select(.mode == "managed") | {address: (.address | mask), action: (.change.actions | action)}]
    | . as $c
    | ([("create", "update", "delete", "replace") as $a | "\([$c[] | select(.action == $a)] | length) to \($a)"]
      | join(", ")) as $counts
    | "### `\($root)`\n\n\($heading)\(if $c == [] then "No changes." else $counts end)\n" as $head
    | {short: $head,
       full: ($head + if $c == [] then "" else
         "\n<details><summary>\($c | length) changes</summary>\n\n"
         + ([$c[] | "- `\(.address)`: \(.action)"] | join("\n")) + "\n\n</details>\n" end)}'
}

# What plan needs of the state of root env: its count of resources, and the public keys of the media key group by
# slot. Those keys are public, and the learner's media-signing.auto.tfvars.json beside the root never reaches CI:
# the applied keys make the plan show the pull request's change alone, not a rotation still on the learner's machine.
state_facts='{count: ([.resources[]?] | length),
  keys: ([.resources[]? | select(.mode == "managed" and .module == "module.media"
      and .type == "aws_cloudfront_public_key" and .name == "media")
    | .instances[]? | select(.deposed == null) | {key: .index_key, value: .attributes.encoded_key}] | from_entries)}'

plan() {
  local env_name=$1 upper tfvars_account tfvars_env pulled open id name values v
  [ "${GITHUB_ACTIONS:-}" = true ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || {
    echo "ci/terraform-plan.sh plan runs in GitHub Actions alone (job plan of plan.yml, with id-token: write):" \
      "it reaches the AWS account of $env_name with the job's OIDC token, never from a dev machine" >&2
    exit 2
  }
  : "${RUNNER_TEMP:?}" "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?}" "${TERRAFORM_IMAGE:?}"
  case $TERRAFORM_IMAGE in *@sha256:*) ;; *) fail "TERRAFORM_IMAGE is not pinned by digest" ;; esac
  upper=$(tr '[:lower:]' '[:upper:]' <<<"$env_name")
  # The other env's id is set only once that env plans too: masked when set, never required.
  for name in "SVP_AWS_${upper}_ACCOUNT_ID" SVP_AWS_LOG_ACCOUNT_ID SVP_AWS_BACKUP_ACCOUNT_ID; do
    [[ ${!name:-} =~ ^[0-9]{12}$ ]] || fail "secret $name of environment terraform-plan is not 12 digits"
  done
  name=SVP_TFVARS_ACCOUNT_$upper tfvars_account=${!name:-}
  [ -n "$tfvars_account" ] || fail "secret $name of environment terraform-plan is empty"
  name=SVP_TFVARS_ENV_$upper tfvars_env=${!name:-}
  [ -n "$tfvars_env" ] || fail "secret $name of environment terraform-plan is empty"
  id=SVP_AWS_${upper}_ACCOUNT_ID
  id=${!id}

  work=$RUNNER_TEMP/svp-plan-$env_name secret=$work/secret masks=$work/masks
  summary_dir=$RUNNER_TEMP/plan-summary/$env_name
  rm -rf "$work" "$summary_dir"
  (umask 077 && mkdir -p "$secret" "$work/accounts" "$work/envs" "$summary_dir") || fail "create $work"
  summary=$summary_dir/summary.md short=$summary_dir/short.md
  printf '## %s\n\n' "$env_name" | tee "$summary" >"$short"
  trap 'rm -rf "$work"; [ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$summary" >>"$GITHUB_STEP_SUMMARY"' EXIT
  : >"$masks"
  for name in SVP_AWS_STG_ACCOUNT_ID SVP_AWS_PRD_ACCOUNT_ID SVP_AWS_LOG_ACCOUNT_ID SVP_AWS_BACKUP_ACCOUNT_ID; do
    [ -z "${!name:-}" ] || add_mask "${!name}"
  done
  for name in SVP_TFVARS_ACCOUNT_$upper SVP_TFVARS_ENV_$upper; do
    values=$(tfvars_values <<<"${!name}" 2>/dev/null) ||
      fail "secret $name holds a heredoc, a block comment or an unterminated string: write each value on one line"
    while IFS= read -r v; do [ -z "$v" ] || add_mask "$v"; done <<<"$values"
  done
  (umask 077 && printf '%s\n' "$tfvars_account" >"$secret/account.tfvars" && printf '%s\n' "$tfvars_env" >"$secret/env.tfvars")

  bucket=svp-tfstate-$id-$region
  export AWS_ROLE_ARN=arn:aws:iam::$id:role/svp-ci-terraform-plan
  export AWS_ROLE_SESSION_NAME=github-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-1}
  export TF_VAR_account_id=$id TF_VAR_backup_account_id=$SVP_AWS_BACKUP_ACCOUNT_ID
  export TF_VAR_log_archive_account_id=$SVP_AWS_LOG_ACCOUNT_ID

  # A session is open when the state of aws/envs/<env> holds a resource: then root account plans with the session's
  # paid features open, as the learner applied it, and root env plans too. The state is read in a pipe, never kept.
  init "aws/envs/$env_name" "aws/$env_name/terraform.tfstate" "$work/envs"
  pulled=$(tf "aws/envs/$env_name" "$work/envs" state pull | jq -cn "(input? // {}) | $state_facts") ||
    fail "terraform state pull of aws/envs/$env_name"
  if [ "$(jq -r .count <<<"$pulled")" -gt 0 ]; then open=true; else open=false; fi

  init "aws/accounts/$env_name" "aws/accounts/$env_name/terraform.tfstate" "$work/accounts"
  plan_root "aws/accounts/$env_name" "$work/accounts" "With \`session_open=$open\`: " \
    -var-file=/run/svp/account.tfvars -var "session_open=$open"
  if [ "$open" = true ]; then
    jq -e '.keys != {}' <<<"$pulled" >/dev/null ||
      fail "the state of aws/envs/$env_name holds no public key of module.media: root env cannot plan without one"
    (umask 077 && jq '{media_signing_public_keys: .keys}' <<<"$pulled" >"$secret/media-signing.tfvars.json")
    plan_root "aws/envs/$env_name" "$work/envs" "" -var-file=/run/svp/env.tfvars \
      -var-file=/run/svp/media-signing.tfvars.json "-var-file=$env_name.tfvars"
  else
    # shellcheck disable=SC2016 # Markdown code, not a command substitution.
    printf '### `aws/envs/%s`\n\nNot planned: no session is open (its state holds no resource).\n' "$env_name" |
      tee -a "$summary" >>"$short"
    notice "aws/envs/$env_name not planned: no session is open (its state holds no resource)"
  fi
}

case "${1:-} $#" in
  'gate 1') gate ;;
  'plan 2')
    case $2 in stg | prd) plan "$2" ;; *) echo "usage: $0 gate | $0 plan stg|prd" >&2; exit 2 ;; esac ;;
  *) echo "usage: $0 gate | $0 plan stg|prd" >&2; exit 2 ;;
esac
