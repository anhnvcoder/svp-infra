#!/usr/bin/env bash
# Self-test of ci/terraform-plan.sh with fake docker, curl and gh first on PATH: no container, account, token or
# network is reached. Runs on the Mac (bash 3.2) and on Linux; needs jq. The script runs from a copy in a tree of its
# own, so the test writes nothing in this repository and can tell whether the script wrote outside $RUNNER_TEMP.

# Usage: ci/terraform-plan-test.sh
#
# The checks run bash -c '...' with their values as arguments ($1, $2, ...), and the expected Markdown holds backquotes.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
command -v jq >/dev/null || {
  echo "FAIL  jq not found" >&2
  exit 1
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
work=$(cd "$work" && pwd)
bin=$work/bin infra=$work/infra log=$work/calls.log
mkdir -p "$bin" "$infra/ci" "$infra/aws/accounts/stg" "$infra/aws/envs/stg"
cp "$src/terraform-plan.sh" "$infra/ci/"
printf 'region = "ap-southeast-1"\n' >"$infra/aws/envs/stg/stg.tfvars"
failures=0

pass() { printf 'ok    %s\n' "$1"; }
bad() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}
# expect NAME CMD...: CMD exits 0.
expect() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else bad "$name"; fi
}

# --- fakes -------------------------------------------------------------------------------------------------------
# docker logs each call (its arguments, the -e variables with their values, the token file and media keys it would
# mount) and answers as terraform: FAKE_SESSION (open, nokeys, empty, destroyed) shapes state pull, FAKE_FAIL (init,
# plan) makes that command fail with the masked values in its stderr, FAKE_PLAN_RC is plan's exit code otherwise.
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
image= workdir= secret= data= prev=
envs=()
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  a=${args[i]}
  case $prev in
    -e) envs+=("$a") ;;
    -w) workdir=$a ;;
    -v) case $a in *:/run/svp:ro) secret=${a%:/run/svp:ro} ;; *:/tfdata) data=${a%:/tfdata} ;; esac ;;
  esac
  [ "$a" != "$FAKE_IMAGE" ] || { image=$i; break; }
  prev=$a
done
tf=("${args[@]:image+1}")
{
  printf 'ARGS'; printf ' %s' "$@"; echo
  for e in "${envs[@]}"; do case $e in *=*) echo "ENV $e" ;; *) echo "ENV $e=${!e:-}" ;; esac; done
  if [ -n "$secret" ]; then
    perm=other
    [ -z "$(find "$secret/token" -perm 0600 2>/dev/null)" ] || perm=600
    echo "TOKEN $(cat "$secret/token") $perm $secret"
    f=$secret/media-signing.tfvars.json
    [ ! -f "$f" ] || echo "MEDIA $(jq -c . "$f") $([ -z "$(find "$f" -perm 0600)" ] || echo 600)"
  fi
  echo "TF ${workdir#/src/} ${tf[*]}"
} >>"$FAKE_LOG"
[ -n "$image" ] || { echo "fake docker: image $FAKE_IMAGE not in the call" >&2; exit 97; }
secrets='stg.aws.svp.example 111111111111 you@svp.example'
case ${tf[0]} in
  init)
    [ "${FAKE_FAIL:-}" != init ] || { echo "Error: S3 bucket svp-tfstate-111111111111-ap-southeast-1 of $secrets: AccessDenied" >&2; exit 1; }
    echo "Initializing the backend: svp-tfstate-111111111111-ap-southeast-1" ;;
  state)
    case ${FAKE_SESSION:-empty} in
      open) cat <<'JSON' ;;
{"version": 4, "resources": [
  {"mode": "managed", "type": "aws_vpc", "name": "this", "instances": [{"attributes": {"owner_id": "111111111111"}}]},
  {"module": "module.media", "mode": "managed", "type": "aws_cloudfront_public_key", "name": "media", "instances": [
    {"index_key": "a", "attributes": {"encoded_key": "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"}},
    {"index_key": "b", "deposed": "00000001", "attributes": {"encoded_key": "old"}}]}]}
JSON
      nokeys) echo '{"version": 4, "resources": [{"mode": "managed", "type": "aws_vpc", "instances": [{"attributes": {}}]}]}' ;;
      destroyed) echo '{"version": 4, "resources": []}' ;;
    esac ;;
  plan)
    echo "PLAN-TEXT $secrets"
    printf 'PLAN-FILE\n' >"$data/plan.tfplan"
    [ "${FAKE_FAIL:-}" != plan ] || { echo "Error: AccessDenied on arn:aws:iam::111111111111:role/x for $secrets" >&2; exit 1; }
    echo "Warning: value for undeclared variable" >&2
    exit "${FAKE_PLAN_RC:-2}" ;;
  show) cat "$FAKE_PLAN_JSON" ;;
  *) echo "fake docker: terraform ${tf[*]} is not expected" >&2; exit 97 ;;
esac
EOF
# curl answers as the token endpoint of Actions: a new token per call, or none with FAKE_NO_TOKEN.
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$FAKE_LOG.tokens" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FAKE_LOG.tokens"
echo "CURL $*" >>"$FAKE_LOG"
[ -z "${FAKE_NO_TOKEN:-}" ] || { echo '{}'; exit 0; }
printf '{"count": 1, "value": "eyJ.tok-%s.oidc"}\n' "$n"
EOF
# gh answers the file list of the pull request (the lines of $FAKE_FILES: name, tab, previous name), runs the --jq of
# a list of comments on $FAKE_COMMENTS, keeps the body a PATCH or POST sends in $FAKE_LOG.body; FAKE_GH_FAIL fails it.
cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "GH $*" >>"$FAKE_LOG"
[ -z "${FAKE_GH_FAIL:-}" ] || exit 1
expr= prev=
for a in "$@"; do
  case $a in body=@*) cp "${a#body=@}" "$FAKE_LOG.body" ;; esac
  [ "$prev" != --jq ] || expr=$a
  prev=$a
done
case " $* " in
  *'/pulls/'*'/files '*) printf '%b' "$FAKE_FILES" ;;
  *' body=@'*) ;;
  *) jq -r "$expr" <<<"${FAKE_COMMENTS:-[]}" ;;
esac
EOF
chmod +x "$bin/docker" "$bin/curl" "$bin/gh"
for c in docker curl gh; do
  [ "$(PATH="$bin:$PATH" command -v "$c")" = "$bin/$c" ] || {
    echo "FAIL  the fake $c is not first on PATH; nothing was run" >&2
    exit 1
  }
done

image=hashicorp/terraform:1.15.8@sha256:7ae513256f7ce67879e218ae8593d6fbe216ec9e123abe6c94e4e10704857963
tfvars_account='# Personal values of the account root.
budget_emails    = ["you@svp.example"] # who gets the budget alerts
budget_limit_usd = 20
zone_name        = "stg.aws.svp.example"
platform_admin_group_id = "0000000000-00000000-0000-0000-0000-000000000001"'
# A quote in an end-of-line comment must not hide the value of the next line.
tfvars_env='hosted_zone_id = "Z0TFVARS" # the zone of "stg
alarm_email    = "alarm@svp.example"
domain         = "stg.aws.svp.example"'
secrets=(111111111111 222222222222 333333333333 444444444444 stg.aws.svp.example you@svp.example Z0TFVARS
  0000000000-00000000-0000-0000-0000-000000000001 alarm@svp.example)

# run NAME ARGS -- VAR=VALUE...: ci/terraform-plan.sh ARGS from the copy, with the fakes, the environment of a plan
# job and VAR=VALUE on top; stdout, stderr and exit code in $out, $err, $rc. AWS_PROFILE of the caller is set to show
# that no variable of the caller reaches docker but those the script names.
run() {
  local name=$1 a=()
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do a+=("$1"); shift; done
  [ $# -eq 0 ] || shift
  rm -rf "$work/runner" "$log" "$log.tokens" "$work/out" "$work/err"
  mkdir -p "$work/runner"
  : >"$log"
  : >"$work/step.md"
  tree >"$work/before"
  rc=0
  env PATH="$bin:$PATH" FAKE_LOG="$log" FAKE_IMAGE="$image" FAKE_PLAN_JSON="$src/testdata/plan.json" \
    GITHUB_ACTIONS=true ACTIONS_ID_TOKEN_REQUEST_URL='https://token.actions.example/x?api-version=2.0' \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token RUNNER_TEMP="$work/runner" GITHUB_STEP_SUMMARY="$work/step.md" \
    GITHUB_OUTPUT="$work/output" GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 TERRAFORM_IMAGE="$image" \
    SVP_AWS_STG_ACCOUNT_ID=111111111111 SVP_AWS_PRD_ACCOUNT_ID=222222222222 SVP_AWS_LOG_ACCOUNT_ID=333333333333 \
    SVP_AWS_BACKUP_ACCOUNT_ID=444444444444 SVP_TFVARS_ACCOUNT_STG="$tfvars_account" SVP_TFVARS_ENV_STG="$tfvars_env" \
    SVP_TFVARS_ACCOUNT_PRD='zone_name = "prd.svp.example"' SVP_TFVARS_ENV_PRD='domain = "prd.svp.example"' \
    AWS_PROFILE=leak \
    "$@" bash "$infra/ci/terraform-plan.sh" "${a[@]}" >"$work/out" 2>"$work/err" || rc=$?
  out=$(cat "$work/out") err=$(cat "$work/err")
  summary=$(cat "$work/runner/plan-summary/stg/summary.md" 2>/dev/null || true)
  short=$(cat "$work/runner/plan-summary/stg/short.md" 2>/dev/null || true)
  : "$name"
}
has() { grep -qF -- "$2" <<<"$1"; }
not() { ! "$@"; }
# tree: each file of the copy with its checksum.
tree() { (cd "$infra" && find . -type f -exec cksum {} + | sort); }
lacks() { ! grep -qF -- "$2" <<<"$1"; }
calls() { grep -c "^$1" "$log" || true; }
# no_secret TEXT: none of the masked values (nor a token) is in TEXT, the add-mask lines left out.
no_secret() {
  local s text
  text=$(grep -v '^::add-mask::' <<<"$1" || true)
  for s in "${secrets[@]}" eyJ.tok PLAN-TEXT; do lacks "$text" "$s" || return 1; done
}
# wrote_outside_runner: a file of the copy changed or appeared in the run, or the runner keeps more than the summary.
wrote_outside_runner() {
  [ "$(tree)" != "$(cat "$work/before")" ] ||
    [ "$(cd "$work/runner" && find . -mindepth 1 -maxdepth 2 | sort | tr '\n' ' ')" != './plan-summary ./plan-summary/stg ' ]
}

# --- refusals ----------------------------------------------------------------------------------------------------
run "outside Actions" plan stg -- GITHUB_ACTIONS=
expect "outside GitHub Actions: plan refuses" test "$rc" -ne 0
expect "outside GitHub Actions: the refusal says why" has "$err" 'runs in GitHub Actions alone'
expect "outside GitHub Actions: no docker, curl or gh call" test ! -s "$log"

run "no token URL" plan stg -- ACTIONS_ID_TOKEN_REQUEST_URL=
expect "without ACTIONS_ID_TOKEN_REQUEST_URL: plan refuses" test "$rc" -ne 0
expect "without ACTIONS_ID_TOKEN_REQUEST_URL: no call" test ! -s "$log"

run "unknown env" plan dev
expect "env dev: refused before any call" bash -c '[ "$1" -ne 0 ] && [ ! -s "$2" ]' _ "$rc" "$log"

run "short account id" plan stg -- SVP_AWS_LOG_ACCOUNT_ID=12345
expect "an account id of 5 digits: refused before any call" bash -c '[ "$1" -ne 0 ] && [ ! -s "$2" ]' _ "$rc" "$log"
expect "an account id of 5 digits: the error names the secret, not its value" \
  bash -c 'grep -qF SVP_AWS_LOG_ACCOUNT_ID <<<"$1" && ! grep -qF 12345 <<<"$1"' _ "$out$err"

run "no id of the env" plan stg -- SVP_AWS_STG_ACCOUNT_ID=
expect "no account id of the env planned: refused before any call" bash -c '[ "$1" -ne 0 ] && [ ! -s "$2" ]' _ "$rc" "$log"

run "empty tfvars" plan stg -- SVP_TFVARS_ENV_STG=
expect "an empty tfvars secret: refused before any call" bash -c '[ "$1" -ne 0 ] && [ ! -s "$2" ]' _ "$rc" "$log"

run "heredoc" plan stg -- SVP_TFVARS_ACCOUNT_STG="$(printf 'zone_name = <<EOT\nstg.aws.svp.example\nEOT')"
expect "a heredoc in a tfvars secret: refused before docker" bash -c '[ "$1" -ne 0 ] && [ "$(grep -c "^ARGS" "$2")" = 0 ]' _ "$rc" "$log"

run "unterminated string" plan stg -- SVP_TFVARS_ENV_STG='domain = "stg.aws.svp.example'
expect "an unterminated string in a tfvars secret: refused before docker" bash -c '[ "$1" -ne 0 ] && [ "$(grep -c "^ARGS" "$2")" = 0 ]' _ "$rc" "$log"

run "image by tag" plan stg -- TERRAFORM_IMAGE=hashicorp/terraform:1.15.8
expect "TERRAFORM_IMAGE without digest: refused before any call" bash -c '[ "$1" -ne 0 ] && [ ! -s "$2" ]' _ "$rc" "$log"

run "no token" plan stg -- FAKE_NO_TOKEN=1
expect "no OIDC token from the endpoint: red, no docker" bash -c '[ "$1" -ne 0 ] && [ "$(grep -c "^ARGS" "$2")" = 0 ]' _ "$rc" "$log"

# --- no session ------------------------------------------------------------------------------------------------
for session in empty destroyed; do
  run "no session ($session)" plan stg -- FAKE_SESSION=$session
  expect "state $session: plan exits 0, nothing on stderr" bash -c '[ "$1" -eq 0 ] && [ -z "$2" ]' _ "$rc" "$err"
  expect "state $session: root account plans with session_open=false" \
    grep -q '^TF aws/accounts/stg plan .* -var session_open=false -out=/tfdata/plan.tfplan$' "$log"
  expect "state $session: root env is not planned" bash -c '! grep -q "^TF aws/envs/stg plan" "$1"' _ "$log"
  expect "state $session: the summary says why root env is not planned" has "$summary" 'Not planned: no session is open'
  expect "state $session: a notice says it in the log" has "$out" '::notice::aws/envs/stg not planned'
  expect "state $session: nothing written outside RUNNER_TEMP, its work directory removed" not wrote_outside_runner
done

# --- open session ----------------------------------------------------------------------------------------------
run "open session" plan stg -- FAKE_SESSION=open
expect "session open: plan exits 0 (plan exit code 2 is changes)" test "$rc" -eq 0
expect "session open: the order is env init, state pull, account init, plan, show, env plan, show" \
  test "$(sed -n 's/^TF \([^ ]*\) \([a-z]*\).*/\1 \2/p' "$log" | tr '\n' ',')" = \
  'aws/envs/stg init,aws/envs/stg state,aws/accounts/stg init,aws/accounts/stg plan,aws/accounts/stg show,aws/envs/stg plan,aws/envs/stg show,'
expect "session open: root account plans with session_open=true and the account tfvars" \
  grep -q '^TF aws/accounts/stg plan -input=false -lock=false -no-color -detailed-exitcode -var-file=/run/svp/account.tfvars -var session_open=true -out=/tfdata/plan.tfplan$' "$log"
expect "session open: root env plans with its secret tfvars and the media keys first, then stg.tfvars (which wins)" \
  grep -q '^TF aws/envs/stg plan -input=false -lock=false -no-color -detailed-exitcode -var-file=/run/svp/env.tfvars -var-file=/run/svp/media-signing.tfvars.json -var-file=stg.tfvars -out=/tfdata/plan.tfplan$' "$log"
expect "session open: the media keys are those of the state by slot, deposed left out, the file mode 600" \
  grep -qxF 'MEDIA {"media_signing_public_keys":{"a":"-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"}} 600' "$log"
expect "session open: neither a slot nor a public key is masked" bash -c '
  ! grep -qxE "::add-mask::(a|b|AAAA|-----BEGIN PUBLIC KEY-----)" <<<"$1"' _ "$out"
expect "init: S3 backend of the env's state bucket, key of the root, region, lock file read-only" bash -c '
  grep -q "^TF aws/envs/stg init -input=false -no-color -lockfile=readonly -backend-config=bucket=svp-tfstate-111111111111-ap-southeast-1 -backend-config=key=aws/stg/terraform.tfstate -backend-config=region=ap-southeast-1$" "$1" &&
  grep -q "^TF aws/accounts/stg init -input=false -no-color -lockfile=readonly -backend-config=bucket=svp-tfstate-111111111111-ap-southeast-1 -backend-config=key=aws/accounts/stg/terraform.tfstate -backend-config=region=ap-southeast-1$" "$1"' _ "$log"
expect "no apply, import, refresh or state write" bash -c '! grep -E "^TF [^ ]+ (apply|destroy|import|refresh|state (push|rm|mv))" "$1"' _ "$log"
expect "every docker call runs TERRAFORM_IMAGE as the caller, the repository read-only" bash -c '
  n=$(grep -c "^ARGS" "$1"); [ "$n" -eq 7 ] &&
  [ "$(grep "^ARGS" "$1" | grep -F -c -- " --user ")" = "$n" ] &&
  [ "$(grep "^ARGS" "$1" | grep -F -c -- " -v $2:/src:ro ")" = "$n" ] &&
  [ "$(grep "^ARGS" "$1" | grep -F -c -- " $3 ")" = "$n" ]' _ "$log" "$infra" "$image"
expect "the role and the web identity token file are all the AWS credential docker gets" bash -c '
  grep "^ENV AWS_" "$1" | sort -u | tr "\n" "," | grep -qx "ENV AWS_REGION=ap-southeast-1,ENV AWS_ROLE_ARN=arn:aws:iam::111111111111:role/svp-ci-terraform-plan,ENV AWS_ROLE_SESSION_NAME=github-42-1,ENV AWS_WEB_IDENTITY_TOKEN_FILE=/run/svp/token,"' _ "$log"
expect "the caller's AWS_PROFILE never reaches docker" bash -c '! grep -q leak "$1"' _ "$log"
expect "TF_VAR_account_id, backup and log archive ids come from the secrets" bash -c '
  grep -q "^ENV TF_VAR_account_id=111111111111$" "$1" && grep -q "^ENV TF_VAR_backup_account_id=444444444444$" "$1" &&
  grep -q "^ENV TF_VAR_log_archive_account_id=333333333333$" "$1"' _ "$log"
expect "a fresh token before each terraform command, audience sts.amazonaws.com" bash -c '
  [ "$(grep "^TOKEN" "$1" | cut -d" " -f2 | sort -u | wc -l | tr -d " ")" = 7 ] &&
  [ "$(grep -c "^CURL .*api-version=2.0&audience=sts.amazonaws.com$" "$1")" = 7 ]' _ "$log"
expect "the token file is mode 600, below RUNNER_TEMP" bash -c '
  [ "$(grep "^TOKEN" "$1" | grep -c " 600 $2/")" = 7 ]' _ "$log" "$work/runner"
expect "every masked value and token has an add-mask line" bash -c '
  shift; out=$1; shift; for s in "$@" eyJ.tok-1.oidc eyJ.tok-7.oidc 20; do
    printf "%s\n" "$out" | grep -qxF "::add-mask::$s" || { echo "no add-mask of $s" >&2; exit 1; }; done' _ x "$out" "${secrets[@]}"
expect "the masked values and the plan text are in neither stdout nor stderr" no_secret "$out$err"
expect "terraform's stderr is not printed when it succeeds" lacks "$err" 'undeclared variable'
expect "the masked values are not in the summary" no_secret "$summary"
expect "the step summary gets the summary" bash -c '[ "$(cat "$1")" = "$2" ]' _ "$work/step.md" "$summary"
expect "nothing written outside RUNNER_TEMP; the plan files and tfvars removed" not wrote_outside_runner

want_changes='- `module.baseline.aws_route53_record.caa["***"]`: create
- `module.registry.aws_iam_role.ci["svp-ci-terraform-plan"]`: create
- `module.media.aws_cloudfront_public_key.media["a"]`: create
- `module.baseline.aws_budgets_budget.monthly`: update
- `module.observability.aws_ssm_parameter.grafana_workspace_id[0]`: delete
- `aws_kms_key.state`: replace
- `module.baseline.aws_route53_zone.this`: replace'
expect "summary: counts of the sample plan, no-op and data sources left out" \
  has "$summary" 'With `session_open=true`: 3 to create, 1 to update, 1 to delete, 2 to replace'
expect "summary: each change's address (masked) and action, in plan order" has "$summary" "$want_changes"
expect "summary: one section per root" bash -c '[ "$(grep -c "^### " <<<"$1")" = 2 ] &&
  grep -qxF "### \`aws/accounts/stg\`" <<<"$1" && grep -qxF "### \`aws/envs/stg\`" <<<"$1"' _ "$summary"
expect "short summary: the counts without the list of changes" bash -c '
  grep -qF "3 to create, 1 to update, 1 to delete, 2 to replace" <<<"$1" && ! grep -qF "aws_kms_key" <<<"$1"' _ "$short"

run "no id of the other env" plan stg -- FAKE_SESSION=open SVP_AWS_PRD_ACCOUNT_ID=
expect "the id of prd unset: stg plans both roots" bash -c '[ "$1" -eq 0 ] && [ "$(grep -c "^TF [^ ]* plan" "$2")" = 2 ]' _ "$rc" "$log"
expect "the id of prd unset: no empty add-mask" bash -c '! grep -qx "::add-mask::" <<<"$1"' _ "$out"

printf '{"format_version": "1.2", "resource_changes": [{"address": "a.b", "mode": "managed", "change": {"actions": ["no-op"]}}]}\n' \
  >"$work/empty.json"
run "no changes" plan stg -- FAKE_PLAN_RC=0 FAKE_PLAN_JSON="$work/empty.json"
expect "plan exit code 0: green, summary says No changes." bash -c '[ "$1" -eq 0 ] && grep -qF "No changes." <<<"$2"' _ "$rc" "$summary"

# --- failures ----------------------------------------------------------------------------------------------------
run "init fails" plan stg -- FAKE_FAIL=init
expect "init fails: red" test "$rc" -ne 0
expect "init fails: terraform's stderr is printed, masked" bash -c 'grep -qF "Error: S3 bucket svp-tfstate-***-ap-southeast-1" <<<"$1"' _ "$err"
expect "init fails: no masked value in stdout or stderr" no_secret "$out$err"
expect "init fails: no plan" bash -c '! grep -q "^TF [^ ]* plan" "$1"' _ "$log"
expect "init fails: the summary says it failed" has "$summary" '**Failed:** terraform init of aws/envs/stg'

run "plan fails" plan stg -- FAKE_FAIL=plan FAKE_SESSION=open
expect "plan fails (exit code 1): red" test "$rc" -ne 0
expect "plan fails: stderr printed masked" has "$err" 'Error: AccessDenied on arn:aws:iam::***:role/x for *** *** ***'
expect "plan fails: no masked value or plan text in stdout or stderr" no_secret "$out$err"
expect "plan fails: no show, no plan of root env" bash -c '! grep -q "^TF [^ ]* show" "$1" && ! grep -q "^TF aws/envs/stg plan" "$1"' _ "$log"
expect "plan fails: nothing left outside the summary" not wrote_outside_runner

run "no media key in the state" plan stg -- FAKE_SESSION=nokeys
expect "an open session without a media key: red after root account, root env not planned" bash -c '
  [ "$1" -ne 0 ] && grep -q "^TF aws/accounts/stg plan" "$2" && ! grep -q "^TF aws/envs/stg plan" "$2"' _ "$rc" "$log"
expect "an open session without a media key: the summary says why" has "$summary" '**Failed:** the state of aws/envs/stg holds no public key'

# --- gate --------------------------------------------------------------------------------------------------------
# gate ENVS FILES [VAR=VALUE...]: the gate of a pull request of this repository, its output in $envs.
gate() {
  local plan_envs=$1 files=$2
  shift 2
  rm -f "$work/output"
  run gate gate -- PLAN_ENVS="$plan_envs" FAKE_FILES="$files" REPO=anhnvcoder/svp-infra HEAD_REPO=anhnvcoder/svp-infra \
    PR=7 CHANGED="$(printf '%b' "$files" | grep -c . || true)" "$@"
  envs=$(sed -n 's/^envs=//p' "$work/output" 2>/dev/null || true)
}
gate '' 'aws/envs/stg/main.tf\t\n'
expect "variable unset: no env, a notice" bash -c '[ "$1" = 0 ] && [ "$2" = "[]" ] && grep -qF "::notice::terraform plan is off" <<<"$3"' _ "$rc" "$envs" "$out"
expect "variable unset: no call to the API" bash -c '! grep -q "^GH" "$1"' _ "$log"
gate '[]' 'aws/envs/stg/main.tf\t\n'
expect "variable []: no env" test "$envs" = '[]'
gate '["stg","prd","stg"]' 'aws/envs/stg/main.tf\t\n'
expect "variable [stg, prd]: both envs, once each" test "$envs" = '["prd","stg"]'
gate '["dev"]' 'aws/envs/stg/main.tf\t\n'
expect "variable [dev]: red" bash -c '[ "$1" -ne 0 ] && [ -z "$2" ]' _ "$rc" "$envs"
gate 'stg' 'aws/envs/stg/main.tf\t\n'
expect "variable not JSON: red" test "$rc" -ne 0
gate '["stg"]' 'aws/envs/stg/main.tf\t\n' HEAD_REPO=someone/svp-infra
expect "pull request from a fork: no env, a notice, no API call" bash -c '
  [ "$1" = "[]" ] && grep -qF "::notice::pull request from the fork someone/svp-infra" <<<"$2" && ! grep -q "^GH" "$3"' _ "$envs" "$out" "$log"
gate '["stg"]' 'aws/envs/stg/.terraform.lock.hcl\t\naws/accounts/stg/.terraform.lock.hcl\t\n' GITHUB_ACTOR='renovate[bot]'
expect "pull request of Renovate: plans like any other" test "$envs" = '["stg"]'
gate '["stg"]' 'aws/org/main.tf\t\ngithub/rulesets.tf\t\naws/gitops/prd/main.tf\t\naws/backup/main.tf\t\ndocs/x.md\t\n'
expect "only roots CI does not plan: no env" test "$envs" = '[]'
expect "only roots CI does not plan: one notice per root, with its reason" bash -c '
  for r in "aws/org is not planned in CI: management account" "github is not planned in CI: needs an admin token" \
    "aws/gitops/prd is not planned in CI: the EKS API" "aws/backup is not planned in CI: runs from the management account"; do
    grep -qF "::notice::$r" <<<"$1" || exit 1; done; grep -qF "::notice::the pull request changes no root CI plans" <<<"$1"' _ "$out"
expect "only roots CI does not plan: the job summary names them" has "$(cat "$work/step.md")" '- aws/org is not planned in CI'
gate '["stg"]' 'aws/org/main.tf\t\naws/modules/registry/main.tf\t\n'
expect "a module and a root CI does not plan: plans, with the notice" bash -c '
  [ "$1" = "[\"stg\"]" ] && grep -qF "::notice::aws/org is not planned in CI" <<<"$2"' _ "$envs" "$out"
gate '["stg"]' 'aws/org/new.tf\taws/envs/stg/old.tf\n'
expect "a file renamed from a planned root: plans" test "$envs" = '["stg"]'
gate '["stg"]' 'aws/org/main.tf\t\n' CHANGED=3000
expect "the API lists fewer files than changed: plans" test "$envs" = '["stg"]'
gate '["stg"]' 'ci/terraform-plan.sh\t\n'
expect "a change of ci/ alone: plans" test "$envs" = '["stg"]'

# --- comment -----------------------------------------------------------------------------------------------------
# Step "Post the summary" of job plan-comment as plan.yml holds it (that job has no checkout, so it cannot call a
# script), run as a run step runs it: bash -e -o pipefail, on the summaries download-artifact leaves.
yml=$src/../.github/workflows/plan.yml
awk '/^      - name: Post the summary$/ {s = 1; next}
  s == 1 && /^        run: [|]$/ {s = 2; next}
  s == 2 {if ($0 != "" && substr($0, 1, 10) != "          ") exit; print substr($0, 11)}' "$yml" >"$work/comment.sh"
expect "plan.yml: the step that posts the comment is found" grep -qF 'svp-terraform-plan' "$work/comment.sh"
# with ACTION: the with: block of the step of plan.yml that uses actions/ACTION.
with() { awk -v a="uses: actions/$1@" 'index($0, a) {s = 1; next} s && /^      - / {exit} s' "$yml"; }
expect "plan.yml: each artifact is the plan-summary directory of the runner, <env>/ inside" \
  has "$(with upload-artifact)" 'path: ${{ runner.temp }}/plan-summary/'
expect "plan.yml: the summaries are downloaded merged, into summaries" bash -c '
  grep -qx " *merge-multiple: true" <<<"$1" && grep -qxF "          path: \${{ runner.temp }}/summaries" <<<"$1"' _ "$(with download-artifact)"
# download DIR...: what download-artifact with merge-multiple leaves, whatever the count of artifacts: the files of
# each artifact (those below the upload path, the runner's plan-summary directory DIR here) in path itself.
download() {
  local d
  rm -rf "$work/ct/summaries"
  mkdir -p "$work/ct/summaries"
  for d in "$@"; do cp -R "$d/." "$work/ct/summaries/"; done
}
# post ENVS [VAR=VALUE...]: the step with the summaries below $work/ct/summaries; the body sent in $body.
post() {
  local envs=$1
  shift
  rm -f "$log" "$log.body"
  : >"$log"
  rc=0
  env PATH="$bin:$PATH" FAKE_LOG="$log" RUNNER_TEMP="$work/ct" GH_TOKEN=gh-token REPO=anhnvcoder/svp-infra PR=7 \
    ENVS="$envs" SHA=0123abc RUN_URL=https://github.example/run/42 "$@" \
    bash --noprofile --norc -e -o pipefail "$work/comment.sh" >"$work/out" 2>"$work/err" || rc=$?
  body=$(cat "$log.body" 2>/dev/null || true)
}
run "a summary for the comment" plan stg -- FAKE_SESSION=open
mkdir -p "$work/artifact" && cp -R "$work/runner/plan-summary" "$work/artifact/stg-run"
download "$work/artifact/stg-run"
post '["stg"]'
expect "comment: one env, so one artifact: its summary as the script wrote it" bash -c '[ "$1" -eq 0 ] && [ -n "$3" ] &&
  grep -qxF "$(head -n 1 <<<"$3")" <<<"$2" && grep -qF "$(tail -n 1 <<<"$3")" <<<"$2" && ! grep -qF "No summary" <<<"$2"' \
  _ "$rc" "$body" "$summary"
mkdir -p "$work/artifact/stg/stg" "$work/artifact/prd/prd"
printf '## stg\n\nSTG-FULL\n' >"$work/artifact/stg/stg/summary.md"
printf '## stg\n\nSTG-SHORT\n' >"$work/artifact/stg/stg/short.md"
printf '## prd\n\nPRD-FULL\n' >"$work/artifact/prd/prd/summary.md"
printf '## prd\n\nPRD-SHORT\n' >"$work/artifact/prd/prd/short.md"
download "$work/artifact/stg" "$work/artifact/prd"
post '["prd","stg"]'
expect "comment: two envs, two artifacts: each env's summary" bash -c '[ "$1" -eq 0 ] &&
  grep -qx "STG-FULL" <<<"$2" && grep -qx "PRD-FULL" <<<"$2" && ! grep -qF "No summary" <<<"$2"' _ "$rc" "$body"
download "$work/artifact/stg"
post '["prd","stg"]'
expect "comment: none yet, so one is posted on the pull request" bash -c '[ "$1" -eq 0 ] &&
  grep -q "^GH api repos/anhnvcoder/svp-infra/issues/7/comments -F body=@" "$2" && ! grep -q -- "-X PATCH" "$2"' _ "$rc" "$log"
expect "comment: the marker first, then each env's summary, one with none says so" bash -c '
  [ "$(head -n 1 <<<"$1")" = "<!-- svp-terraform-plan -->" ] && grep -qF "Commit 0123abc, [run](https://github.example/run/42)" <<<"$1" &&
  grep -qx "STG-FULL" <<<"$1" && grep -qF "No summary: the plan did not finish" <<<"$1"' _ "$body"
post '["stg"]' FAKE_COMMENTS='[{"id": 5, "user": {"login": "someone"}, "body": "<!-- svp-terraform-plan --> quoted"},
  {"id": 8, "user": {"login": "github-actions[bot]"}, "body": "other"},
  {"id": 9, "user": {"login": "github-actions[bot]"}, "body": "<!-- svp-terraform-plan -->\nold"}]'
expect "comment: the bot's comment with the marker is edited, nobody else's" bash -c '[ "$1" -eq 0 ] &&
  grep -q "^GH api -X PATCH repos/anhnvcoder/svp-infra/issues/comments/9 -F body=@" "$2" &&
  [ "$(grep -c "^GH api.* -F body=@" "$2")" = 1 ]' _ "$rc" "$log"
awk 'BEGIN {for (i = 0; i < 1300; i++) printf "- `module.x.aws_y.z[%d]`: create with a long address\n", i}' \
  >"$work/ct/summaries/stg/summary.md"
post '["stg"]'
expect "comment: over 60000 bytes, the counts alone and a pointer to the job summary" bash -c '
  [ "${#1}" -le 60000 ] && grep -qx "STG-SHORT" <<<"$1" && ! grep -qF "module.x" <<<"$1" &&
  grep -qF "too long for a comment: see the job summary" <<<"$1"' _ "$body"
post '["stg"]' FAKE_GH_FAIL=1
expect "comment: the API fails, the step is red" test "$rc" -ne 0

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
