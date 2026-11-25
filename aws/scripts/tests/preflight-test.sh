#!/usr/bin/env bash
# Self-test of preflight.sh against a fake aws and real git clones in a temporary tree: every subcommand has a check
# for its ok path and one for each FAIL it names; apart from "quotas <env> request" no call of aws is a write; findings
# keeps resource ids out of its output; promote calls no aws; --print reaches nothing.

# Usage: aws/scripts/tests/preflight-test.sh
#
# The checks run sh -c '...' with their values as arguments ($1, $2, ...): expanded by that shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=aws/scripts/tests/testlib.sh
. "$src/tests/testlib.sh"
fake_aws
# The fake of testlib answers one file per command key; this one in front of it picks the answer by a part of the call
# (a quota code, an add-on, a filter), and writes the profile of each call to $log.profiles.
mv "$bin/aws" "$bin/aws-base"
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "$AWS_PROFILE $*" >>"$FAKE_LOG.profiles"
ckey=
for a in "$@"; do
  case $a in -*) break ;; esac
  ckey=${ckey:+${ckey}_}$a
done
if [ -f "$FAKE_ERRORS/$ckey" ]; then
  echo "aws $*" >>"$FAKE_LOG"
  cat "$FAKE_ERRORS/$ckey" >&2
  exit 254
fi
n=0
if [ -f "$FAKE_SEL" ]; then
  while IFS=$'\t' read -r key pat; do
    n=$((n + 1))
    [ "$key" = "$ckey" ] || continue
    case " $* " in
      *"$pat"*)
        if [ "$(cat "$FAKE_SEL_DIR/$n")" = @fail ]; then
          echo "fake aws: ParameterNotFound for '$pat'" >&2
          exit 254
        fi
        d=$(mktemp -d)
        cp "$FAKE_SEL_DIR/$n" "$d/$key"
        FAKE_ANSWERS=$d "$(dirname "$0")/aws-base" "$@" && rc=0 || rc=$?
        rm -rf "$d"
        exit $rc
        ;;
    esac
  done <"$FAKE_SEL"
fi
exec "$(dirname "$0")/aws-base" "$@"
EOF
chmod +x "$bin/aws"
export FAKE_SEL=$work/sel.tsv FAKE_SEL_DIR=$work/sel FAKE_ERRORS=$work/errors
mkdir -p "$FAKE_SEL_DIR" "$FAKE_ERRORS"
# sel KEY PART BODY: a call whose arguments contain PART is answered with BODY as the answer of command KEY.
sel() {
  local n
  n=$(awk -F '\t' -v k="$1" -v p="$2" '$1 == k && $2 == p { print NR }' "$FAKE_SEL" 2>/dev/null || true)
  if [ -z "$n" ]; then
    printf '%s\t%s\n' "$1" "$2" >>"$FAKE_SEL"
    n=$(grep -c . "$FAKE_SEL")
  else
    awk -F '\t' -v n="$n" -v k="$1" 'BEGIN { OFS = FS } NR == n { $1 = k } { print }' "$FAKE_SEL" >"$FAKE_SEL.new"
    mv "$FAKE_SEL.new" "$FAKE_SEL"
  fi
  printf '%b\n' "$3" >"$FAKE_SEL_DIR/$n"
}
sel_reset() {
  rm -rf "$FAKE_SEL" "$FAKE_SEL_DIR"
  mkdir -p "$FAKE_SEL_DIR"
  : >"$log"
  : >"$log.profiles"
  rm -f "$answers"/* "$FAKE_ERRORS"/*
}
# ans KEY BODY: the answer of command KEY.
ans() { printf '%b\n' "$2" >"$answers/$1"; }
# ans_err KEY [MESSAGE]: command KEY fails as aws does, MESSAGE on stderr, exit 254; without MESSAGE it answers again.
ans_err() {
  if [ $# -ge 2 ]; then printf '%b\n' "$2" >"$FAKE_ERRORS/$1"; else rm -f "$FAKE_ERRORS/$1"; fi
}

here=$work/infra/aws/scripts
mkdir -p "$here" "$work/infra/aws/envs/stg" "$work/infra/aws/envs/prd"
cp "$src/lib.sh" "$src/profiles.sh" "$src/preflight.sh" "$here/"
printf 'kubernetes_version = "1.36"\n' >"$work/infra/aws/envs/stg/stg.tfvars"
printf 'kubernetes_version = "1.36"\n' >"$work/infra/aws/envs/prd/prd.tfvars"
printf '{}\n' >"$work/infra/aws/paid-features.json"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
# nodepool DIR STG_OVERLAY: DIR/gitops, a clone whose origin/main has the base NodePool (limits.cpu 32) and the stg
# overlay with the given body.
nodepool() {
  mkdir -p "$1/src-np/envs/stg" "$1/src-np/platforms/eks"
  git init -q -b main "$1/src-np"
  printf 'resources:\n  limits:\n    cpu: 2\nkarpenter:\n  enabled: true\n  limits:\n    cpu: 32\n' \
    >"$1/src-np/platforms/eks/svp-cluster.yaml"
  printf '%b' "$2" >"$1/src-np/envs/stg/svp-cluster.yaml"
  git -C "$1/src-np" add -A
  git -C "$1/src-np" commit -q -m nodepool
  git clone -q "$1/src-np" "$1/gitops"
}
nodepool "$work" 'karpenter:\n  capacityTypes: [spot]\n  limits:\n    cpu: 16\n    memory: 64Gi\n'
export SVP_AWS_MGMT_ACCOUNT_ID=000000000000 SVP_AWS_STG_ACCOUNT_ID=111111111111 SVP_AWS_PRD_ACCOUNT_ID=222222222222
export SVP_AWS_SECURITY_ACCOUNT_ID=444444444444 SVP_AWS_BACKUP_ACCOUNT_ID=555555555555
export SVP_GITOPS_DIR=$work/gitops SVP_BACKEND_DIR=$work/backend-none
out=$work/out err=$work/err
run() { bash "$here/preflight.sh" "$@" >"$out" 2>"$err"; }
# renv ENV... CMD...: CMD with the environment changes, its output where run puts it.
renv() { env "$@" >"$out" 2>"$err"; }
# fails NAME GREP CMD...: CMD exits non-zero with a FAIL line matching GREP on stderr.
fails() {
  local name=$1 pattern=$2
  shift 2
  if "$@"; then
    bad "$name: exits 0"
    return 0
  fi
  expect "$name: FAIL" grep -q "^FAIL  .*$pattern" "$err"
}
no_writes() { ! grep -Eq '^aws [^ ]+ (create|put|delete|update|request|start|tag|untag|modify|send|run|enable|disable)-' "$log"; }

# --- quotas ---
quotas_ok() {
  sel_reset
  sel service-quotas_get-service-quota "--quota-code L-1216C47A" "10.0"
  sel service-quotas_get-service-quota "--quota-code L-34B43A08" "16.0"
  sel service-quotas_get-service-quota "--quota-code L-0263D0A3" "5.0"
  sel service-quotas_get-service-quota "--quota-code L-AMP1" "15.0"
  ans service-quotas_list-aws-default-service-quotas "L-AMP1\tRule evaluation interval\t30.0\tTrue"
  ans service-quotas_list-requested-service-quota-change-history-by-quota ""
}
quotas_ok
expect "quotas stg exits 0, four ok lines" sh -c 'bash "$1/preflight.sh" quotas stg >"$2" 2>"$3" && test "$(grep -c "^ok    L-" "$2")" = 4' _ "$here" "$out" "$err"
expect "quotas stg: no write call, region ap-southeast-1 and the profile of the env" \
  sh -c '! grep -v " --region ap-southeast-1$" "$1" && ! grep -v "^anhnv-stg " "$2"' _ "$log" "$log.profiles"
expect "quotas stg: no request, no write" no_writes
expect "quotas stg: check_account first" sh -c 'head -n 1 "$1" | grep -q "^aws sts get-caller-identity"' _ "$log"
sel service-quotas_get-service-quota "--quota-code L-1216C47A" "5.0"
fails "quotas stg: on-demand 5 against 10" 'L-1216C47A vCPU on-demand (Standard): 5.0, needs min 10: run preflight.sh quotas stg request' run quotas stg
expect "quotas stg short: the other quotas still checked, nothing requested" \
  sh -c 'grep -q "^ok    L-0263D0A3" "$1" && ! grep -q request-service-quota-increase "$2"' _ "$out" "$log"
sel service-quotas_get-service-quota "--quota-code L-34B43A08" "12.0"
fails "quotas stg: Spot 12 against limits.cpu 16" 'L-34B43A08 .*: 12.0, needs min 16' run quotas stg
printf 'karpenter:\n  limits:\n    cpu: 99\n' >"$work/gitops/envs/stg/svp-cluster.yaml"
fails "quotas stg: limits.cpu is read on origin/main, not the working tree" 'L-34B43A08 .*: 12.0, needs min 16: run' run quotas stg
git -C "$work/gitops" checkout -q envs/stg/svp-cluster.yaml
mkdir -p "$work/np2"
nodepool "$work/np2" 'karpenter:\n  capacityTypes: [spot]\n'
fails "quotas stg: an overlay without limits takes limits.cpu of the base file" 'L-34B43A08 .*: 12.0, needs min 32' \
  renv SVP_GITOPS_DIR="$work/np2/gitops" bash "$here/preflight.sh" quotas stg
SVP_GITOPS_DIR=$work/none run quotas stg 2>/dev/null && true
expect "quotas stg without the NodePool file: note and the floor 10 (12 is enough)" \
  sh -c 'grep -q "^note  no limits.cpu in " "$1" && grep -q "^ok    L-34B43A08" "$2"' _ "$err" "$out"
quotas_ok
sel service-quotas_get-service-quota "--quota-code L-AMP1" "30.0"
expect "quotas stg: AMP rule interval 30 at the default quota is ok (max 30)" \
  sh -c 'bash "$1/preflight.sh" quotas stg >"$2" 2>"$3" && grep -qx "ok    L-AMP1 AMP rule evaluation interval (seconds): 30.0 (max 30)" "$2"' _ "$here" "$out" "$err"
sel service-quotas_list-requested-service-quota-change-history-by-quota "--quota-code L-AMP1" "r-15\tCASE_OPENED\t15.0"
expect "quotas stg: AMP 30 with a 15 s request open is still ok, no FAIL" \
  sh -c 'bash "$1/preflight.sh" quotas stg >"$2" 2>"$3" && grep -q "^ok    L-AMP1 .*: 30.0 (max 30)" "$2" && ! grep -q "^FAIL" "$3"' _ "$here" "$out" "$err"
ans service-quotas_list-aws-default-service-quotas ""
fails "quotas stg: no AMP quota named like the runbook says" "hold 0 line" run quotas stg
quotas_ok
fails "quotas prd: needs 14 + limits.cpu 32 of the base file, and the Spot row is absent" 'L-1216C47A .*: 10.0, needs min 46' run quotas prd
expect "quotas prd: the prd rows only (no Spot), all with anhnv-prd" \
  sh -c 'grep -q "^ok    L-0263D0A3 Elastic IP: 5.0 (min 3)" "$1" && ! grep -q L-34B43A08 "$2" && ! grep -v "^anhnv-prd " "$3"' _ "$out" "$log" "$log.profiles"
sel service-quotas_get-service-quota "--quota-code L-1216C47A" "46.0"
expect "quotas prd: 46 vCPU on-demand is enough" sh -c 'bash "$1/preflight.sh" quotas prd >"$2" 2>&1 && grep -q "^ok    L-1216C47A .*: 46.0 (min 46)" "$2"' _ "$here" "$out"
sel service-quotas_get-service-quota "--quota-code L-AMP1" "30.0"
expect "quotas prd: AMP rule interval 30 at the default quota is ok (max 30)" \
  sh -c 'bash "$1/preflight.sh" quotas prd >"$2" 2>&1 && grep -qx "ok    L-AMP1 AMP rule evaluation interval (seconds): 30.0 (max 30)" "$2"' _ "$here" "$out"
sel service-quotas_get-service-quota "--quota-code L-AMP1" "60.0"
fails "quotas prd: AMP rule interval 60 against max 30" \
  'L-AMP1 AMP rule evaluation interval (seconds): 60.0, needs max 30: run preflight.sh quotas prd request' run quotas prd
sel service-quotas_get-service-quota "--quota-code L-AMP1" "30.0"
SVP_GITOPS_DIR=$work/none run quotas prd 2>/dev/null && true
expect "quotas prd without the NodePool file: note and the floor 16" \
  sh -c 'grep -q "^note  no limits.cpu in envs/prd/svp-cluster.yaml or platforms/eks/svp-cluster.yaml" "$1" && grep -q "^ok    L-1216C47A .*(min 16)" "$2"' _ "$err" "$out"
sel_reset
sel service-quotas_get-service-quota "--quota-code L-1216C47A" "5.0"
sel service-quotas_get-service-quota "--quota-code L-34B43A08" "16.0"
sel service-quotas_get-service-quota "--quota-code L-0263D0A3" "5.0"
sel service-quotas_get-service-quota "--quota-code L-AMP1" "15.0"
ans service-quotas_list-aws-default-service-quotas "L-AMP1\tRule evaluation interval\t30.0\tTrue"
ans service-quotas_request-service-quota-increase "r-123\tPENDING"
ans service-quotas_list-requested-service-quota-change-history-by-quota ""
expect "quotas stg request: exits 0" run quotas stg request
expect "quotas stg request: asks for 10 on L-1216C47A and only for it" \
  sh -c 'grep -c "request-service-quota-increase" "$1" | grep -qx 1 && grep -q "^aws service-quota.* request-service-quota-increase --service-code ec2 --quota-code L-1216C47A --desired-value 10 " "$1"' _ "$log"
expect "quotas stg request: a note names the request" grep -q '^note  L-1216C47A .*asked for 10 (r-123 PENDING)' "$out"
sel service-quotas_list-requested-service-quota-change-history-by-quota "--quota-code L-1216C47A" "r-123\tCASE_OPENED\t10.0"
: >"$log"
expect "quotas stg request again: exits 0" run quotas stg request
expect "quotas stg request again: no second request, a note" \
  sh -c '! grep -q request-service-quota-increase "$1" && grep -q "^note  L-1216C47A .*already open (r-123 CASE_OPENED 10.0): not sent again" "$2"' _ "$log" "$out"
fails "quotas stg (read) with a request open: FAIL says wait" 'a request is open (r-123 CASE_OPENED 10.0)' run quotas stg
sel_reset
sel service-quotas_get-service-quota "--quota-code L-AMP1" "30.0"
ans service-quotas_list-aws-default-service-quotas "L-AMP1\tRule evaluation interval\t30.0\tTrue"
ans service-quotas_get-service-quota "10.0"
ans service-quotas_list-requested-service-quota-change-history-by-quota ""
ans service-quotas_request-service-quota-increase "r-9\tPENDING"
run quotas stg request || true
expect "quotas stg request: the AMP interval at 30 is not asked for" \
  sh -c 'grep -q "^ok    L-AMP1 .*: 30.0 (max 30)" "$1" && ! grep -q "request-service-quota-increase --service-code aps" "$2"' _ "$out" "$log"
sel_reset
sel service-quotas_get-service-quota "--quota-code L-AMP1" "30.0"
ans service-quotas_list-aws-default-service-quotas "L-AMP1\tRule evaluation interval\t30.0\tTrue"
ans service-quotas_get-service-quota "10.0"
ans service-quotas_list-requested-service-quota-change-history-by-quota ""
ans service-quotas_request-service-quota-increase "r-9\tPENDING"
run quotas prd request || true
expect "quotas prd request: the AMP interval at 30 is not asked for" \
  sh -c 'grep -q "^ok    L-AMP1 .*: 30.0 (max 30)" "$1" && ! grep -q "request-service-quota-increase --service-code aps" "$2"' _ "$out" "$log"
sel_reset
quotas_ok
fails "quotas stg with SVP_AWS_STG_ACCOUNT_ID of another account" 'profile anhnv-stg is account .111111111111.' renv SVP_AWS_STG_ACCOUNT_ID=999999999999 bash "$here/preflight.sh" quotas stg
expect "quotas stg wrong account: no quota call" sh -c '! grep -q service-quotas "$1"' _ "$log"
expect "quotas mgmt is refused" sh -c '! bash "$1/preflight.sh" quotas mgmt >/dev/null 2>&1' _ "$here"
expect "quotas stg ask: an unknown word is refused" sh -c '! bash "$1/preflight.sh" quotas stg ask >/dev/null 2>&1' _ "$here"

# --- freetier ---
sel_reset
ans pricing-plan-manager_list-subscriptions '[]'
ans freetier_get-account-plan-state 'PAID'
expect "freetier stg exits 0" run freetier stg
expect "freetier stg: two ok lines, both in us-east-1 with anhnv-stg, no write" \
  sh -c 'test "$(grep -c "^ok    no CloudFront\|^ok    account plan" "$1")" = 2 && grep -q "^aws pricing-plan-manager list-subscriptions .* --region us-east-1$" "$2" && ! grep -v "^anhnv-stg " "$3"' _ "$out" "$log" "$log.profiles"
expect "freetier stg: no write call" no_writes
ans freetier_get-account-plan-state 'FREE'
fails "freetier stg: FREE" 'account plan of stg is FREE' run freetier stg
expect "freetier stg FREE: the plans line is still checked" grep -q '^ok    no CloudFront' "$out"
ans freetier_get-account-plan-state 'PAID'
ans pricing-plan-manager_list-subscriptions '[["arn:aws:pricingplanmanager:::subscription/s1","FLAT_RATE_FREE","ACTIVE"]]'
fails "freetier prd: a plan left" '1 CloudFront plan(s) left in prd (FLAT_RATE_FREE ACTIVE)' run freetier prd
expect "freetier prd: the arn is not printed" sh -c '! grep -q "subscription/s1" "$1" "$2"' _ "$out" "$err"
ans pricing-plan-manager_list-subscriptions '[]'
ans freetier_get-account-plan-state 'UPGRADING'
fails "freetier stg: any other state" "account plan of stg is 'UPGRADING', not PAID" run freetier stg
# A member account of an organization has no account plan (the answer of stg and prd).
ans_err freetier_get-account-plan-state '\nAn error occurred (ResourceNotFoundException) when calling the GetAccountPlanState operation: Missing data for account'
expect "freetier stg: ResourceNotFoundException (member account) exits 0" run freetier stg
expect "freetier stg member account: PAID, as a member of an organization" \
  grep -qx 'ok    account plan of stg is PAID (member of an organization, no account plan)' "$out"
ans_err freetier_get-account-plan-state '\nAn error occurred (AccessDeniedException) when calling the GetAccountPlanState operation: not authorized'
fails "freetier stg: any other error" 'freetier get-account-plan-state with profile anhnv-stg: .*AccessDeniedException' run freetier stg
expect "freetier stg other error: no ok line for the plan" sh -c '! grep -q "^ok    account plan" "$1"' _ "$out"
ans_err freetier_get-account-plan-state

# --- eks-upgrade ---
eks_ok() {
  sel_reset
  ans eks_describe-cluster-versions '1.36\tSTANDARD_SUPPORT\t2027-03-01\n1.37\tSTANDARD_SUPPORT\t2027-06-01'
  ans eks_describe-addon-versions 'v1.2.3-eksbuild.1'
  sel ssm_get-parameter "release_version" "1.37.2-20261101"
  sel ssm_get-parameter "standard-1.36-v20261101/image_id" "ami-0aaa111"
  sel ssm_get-parameter "standard-1.37-v20261101/image_id" "ami-0bbb222"
}
eks_ok
expect "eks-upgrade stg exits 0" run eks-upgrade stg
expect "eks-upgrade stg: the table for 1.37 (account, minor, seven add-ons, release, two AMIs) and two notes" \
  sh -c 'test "$(grep -c "^ok    " "$1")" = 12 && grep -q "^ok    EKS 1.37  *STANDARD_SUPPORT until 2027-06-01" "$1" && grep -q "AMI release_version  *1.37.2-20261101 (alias al2023@v20261101)" "$1" && grep -q "AMI 1.36 at v20261101  *ami-0aaa111" "$1" && test "$(grep -c "^note  " "$1")" = 2' _ "$out"
expect "eks-upgrade stg: no write call, region ap-southeast-1" sh -c '! grep -v " --region ap-southeast-1$" "$1"' _ "$log"
expect "eks-upgrade stg: no write call" no_writes
ans eks_describe-cluster-versions '1.36\tSTANDARD_SUPPORT\t2027-03-01\n1.37\tEXTENDED_SUPPORT\t2027-06-01'
fails "eks-upgrade stg: 1.37 not in standard support" 'EKS 1.37 is EXTENDED_SUPPORT until 2027-06-01, not STANDARD_SUPPORT' run eks-upgrade stg
ans eks_describe-cluster-versions '1.36\tSTANDARD_SUPPORT\t2027-03-01'
fails "eks-upgrade stg: EKS does not list 1.37" 'EKS lists no minor 1.37' run eks-upgrade stg
eks_ok
sel eks_describe-addon-versions "--addon-name coredns" "None"
fails "eks-upgrade stg: an add-on with no version" 'add-on coredns has no version for EKS 1.37' run eks-upgrade stg
expect "eks-upgrade stg: the other add-ons are still read" sh -c 'test "$(grep -c "^ok    add-on" "$1")" = 6' _ "$out"
eks_ok
sel ssm_get-parameter "release_version" "1.36.9-20261101"
fails "eks-upgrade stg: release_version of another minor" "release_version '1.36.9-20261101' is not 1.37" run eks-upgrade stg
eks_ok
sel ssm_get-parameter "standard-1.36-v20261101/image_id" @fail
fails "eks-upgrade stg: no image for the date" 'image_id of 1.36 at v20261101' run eks-upgrade stg
eks_ok
sel ssm_get-parameter "standard-1.37-v20261101/image_id" "not-an-ami"
fails "eks-upgrade stg: image id not ami-" "image id of 1.37 at v20261101 is 'not-an-ami'" run eks-upgrade stg

# --- findings ---
export SVP_SESSION_DIR=$work/infra/.session/t1
mkdir -p "$SVP_SESSION_DIR"
printf '2026-11-15T01:00:00Z\t1\tstart\n' >"$SVP_SESSION_DIR/timeline.tsv"
vault_ok() {
  sel_reset
  ans backup_describe-backup-vault 'arn:aws:kms:ap-southeast-1:555555555555:key/kvault'
  ans backup_list-recovery-points-by-backup-vault '{"RecoveryPoints": [
    {"ResourceType": "RDS", "Status": "COMPLETED", "CreationDate": "2026-11-15T02:00:00+00:00", "CalculatedLifecycle": {"DeleteAt": "2026-11-22T02:00:00+00:00"}, "EncryptionKeyArn": "arn:aws:kms:ap-southeast-1:555555555555:key/kvault", "RecoveryPointArn": "arn:aws:rds:secret-arn"},
    {"ResourceType": "S3", "Status": "COMPLETED", "CreationDate": "2026-11-15T02:01:00+00:00", "EncryptionKeyArn": "arn:aws:kms:ap-southeast-1:555555555555:key/kvault"}]}'
}
hub_ok() {
  vault_ok
  printf '{"stg": {"security_hub": "always"}}\n' >"$work/infra/aws/paid-features.json"
  sel securityhub_get-findings "ComplianceStatus" 'S3.1\tHIGH\tAwsS3Bucket\tarn:aws:s3:::secret-bucket-name\nS3.1\tHIGH\tAwsS3Bucket\tarn:aws:s3:::other-bucket\nIAM.4\tCRITICAL\tAwsIamUser\tadmin-user'
  sel securityhub_get-findings "ProductName" 'GuardDuty\tHIGH\tRecon:EC2/Portscan\tPort probe on an instance'
}
hub_ok
expect "findings stg (security_hub on) exits 0" run findings stg
expect "findings stg: the copy vault is read with anhnv-backup-ro, Security Hub with anhnv-security-ro" \
  sh -c 'grep -q "^anhnv-backup-ro backup list-recovery-points-by-backup-vault --backup-vault-name svp-stg-copy --by-created-after 2026-11-15T01:00:00Z " "$1" && grep -q "^anhnv-security-ro securityhub get-findings " "$1"' _ "$log.profiles"
expect "findings stg: each profile is checked once before its first command" \
  sh -c 'test "$(grep -c "sts get-caller-identity" "$1")" = 3 && grep -q "^aws sts get-caller-identity" "$2"' _ "$log.profiles" "$log"
expect "findings stg: the filter holds the account of the env, not another" \
  sh -c 'grep "securityhub get-findings" "$1" | grep -q "\"Value\":\"111111111111\"" && ! grep "securityhub get-findings" "$1" | grep -q 555555555555' _ "$log"
expect "findings stg: counts by control, severity, type are printed" \
  grep -q '^note  Security Hub FAILED control x2: S3.1 HIGH AwsS3Bucket' "$out"
expect "findings stg: no resource id, ARN or user name in the output" no_leak secret-bucket-name "$out" "$err"
expect "findings stg: no ARN of the recovery points in the output" no_leak secret-arn "$out" "$err"
expect "findings stg: resource ids are in controls-failed.tsv of the session, mode 600" \
  sh -c 'grep -q secret-bucket-name "$1" && test "$(ls -l "$1" | cut -c1-10)" = "-rw-------"' _ "$SVP_SESSION_DIR/controls-failed.tsv"
expect "findings stg: the copy vault line and the GuardDuty finding are printed" \
  sh -c 'grep -q "^ok    svp-stg-copy: every recovery point COMPLETED under the key of the vault" "$1" && grep -q "^note  finding x1 since the start: GuardDuty.*Port probe" "$1"' _ "$out"
expect "findings stg: no write call" no_writes
sel securityhub_get-findings "ComplianceStatus" ''
expect "findings stg without FAILED control: ok line" sh -c 'bash "$1/preflight.sh" findings stg >"$2" 2>&1 && grep -q "^ok    Security Hub: no FAILED control" "$2"' _ "$here" "$out"
hub_ok
ans backup_list-recovery-points-by-backup-vault '{"RecoveryPoints": [{"ResourceType": "RDS", "Status": "COMPLETED", "CreationDate": "2026-11-15T02:00:00+00:00", "EncryptionKeyArn": "arn:aws:kms:other"}]}'
fails "findings stg: a recovery point under another key" '1 recovery point.s. of svp-stg-copy not COMPLETED or not under the key of the vault' run findings stg
expect "findings stg: the security findings are still read" grep -q '^note  Security Hub FAILED control' "$out"
ans backup_list-recovery-points-by-backup-vault '{"RecoveryPoints": []}'
fails "findings stg: no recovery point in the copy vault" 'no recovery point in svp-stg-copy created after 2026-11-15T01:00:00Z' run findings stg
hub_ok
rm "$SVP_SESSION_DIR/timeline.tsv"
fails "findings stg: no timeline.tsv" 'no .*timeline.tsv: the session has not started' run findings stg
expect "findings stg without timeline: no aws call" test ! -s "$log"
printf 'not a time\n' >"$SVP_SESSION_DIR/timeline.tsv"
fails "findings stg: first line of timeline.tsv is not a time" "starts with 'not a time'" run findings stg
printf '2026-11-15T01:00:00Z\t1\tstart\n' >"$SVP_SESSION_DIR/timeline.tsv"
fails "findings stg: SVP_SESSION_DIR unset" 'set SVP_SESSION_DIR first' renv -u SVP_SESSION_DIR bash "$here/preflight.sh" findings stg
fails "findings stg: SVP_SESSION_DIR outside .session" 'is not under' renv SVP_SESSION_DIR=/tmp/x bash "$here/preflight.sh" findings stg
fails "findings stg: SVP_AWS_STG_ACCOUNT_ID not set" 'set SVP_AWS_STG_ACCOUNT_ID to the 12 digits' renv -u SVP_AWS_STG_ACCOUNT_ID bash "$here/preflight.sh" findings stg
hub_ok
fails "findings stg: the security account is another one" 'profile anhnv-security-ro is account .444444444444.' renv SVP_AWS_SECURITY_ACCOUNT_ID=999999999999 bash "$here/preflight.sh" findings stg
expect "findings stg wrong security account: no securityhub call, the vault still read" \
  sh -c '! grep -q securityhub "$1" && grep -q list-recovery-points "$1"' _ "$log"
# security_hub off: GuardDuty at the delegated administrator, in the region and in us-east-1.
vault_ok
printf '{"stg": {"security_hub": "off"}}\n' >"$work/infra/aws/paid-features.json"
ans guardduty_list-detectors 'det1'
ans guardduty_list-findings 'id1\tid2'
ans guardduty_get-findings '5.0\tRecon:EC2/Portscan\tPort probe\n8.0\tTrojan:EC2/X\tBad thing'
sel securityhub_get-findings "ProductName" 'IAM Access Analyzer\tHIGH\tEffects/Data Exposure\tExternal access to a bucket'
expect "findings stg (security_hub off) exits 0" run findings stg
expect "findings stg off: GuardDuty read with anhnv-security-ro in both regions, since the session start, for the account" \
  sh -c 'test "$(grep -c "^aws guardduty list-findings --detector-id det1 --max-items 50 --finding-criteria .*\"accountId\":{\"Equals\":\[\"111111111111\"\]}.*\"GreaterThanOrEqual\":1794704400000" "$1")" = 2 && grep -q "^aws guardduty list-detectors --query DetectorIds.0. --output text --region us-east-1$" "$1"' _ "$log"
expect "findings stg off: Security Hub still read once for Access Analyzer, no control query" \
  sh -c 'test "$(grep -c "^aws securityhub get-findings .*ProductName.*\"IAM Access Analyzer\"" "$1")" = 1 && ! grep -q ComplianceStatus "$1" && grep -q "^anhnv-security-ro securityhub get-findings " "$2"' _ "$log" "$log.profiles"
expect "findings stg off: the Access Analyzer finding is printed" \
  grep -q '^note  finding x1 since the start: IAM Access Analyzer HIGH Effects/Data Exposure External access to a bucket' "$out"
expect "findings stg off: no write call" no_writes
sel securityhub_get-findings "ProductName" ''
expect "findings stg off: no Access Analyzer finding is an ok line" \
  sh -c 'bash "$1/preflight.sh" findings stg >"$2" 2>&1 && grep -q "^ok    Security Hub: no GuardDuty or Access Analyzer finding since" "$2"' _ "$here" "$out"
expect "findings stg off: severity, type and title, worst first" \
  sh -c 'grep -q "^note  GuardDuty ap-southeast-1 severity 8.0 .*: Trojan:EC2/X, Bad thing" "$1" && grep -q "^note  security_hub of stg is off" "$1"' _ "$out"
ans guardduty_list-detectors 'None'
fails "findings stg off: no GuardDuty detector" 'no GuardDuty detector in ap-southeast-1' run findings stg
ans guardduty_list-detectors 'det1'
ans guardduty_list-findings 'None'
expect "findings stg off: none is an ok line" sh -c 'bash "$1/preflight.sh" findings stg >"$2" 2>&1 && grep -q "^ok    GuardDuty us-east-1: no finding" "$2"' _ "$here" "$out"
expect "findings prd reads svp-prd-copy" sh -c 'env SVP_AWS_PRD_ACCOUNT_ID=222222222222 bash "$1/preflight.sh" findings prd >/dev/null 2>&1; grep -q "backup-vault-name svp-prd-copy" "$2"' _ "$here" "$log"

# --- promote ---
# build DIR [VARIANT...]: DIR/backend and DIR/gitops, clones of repositories DIR/src-*, as the gate finds them; a
# variant leaves out one thing the gate reads.
build() {
  local d=$1 v
  shift
  v=" $* "
  git init -q -b main "$d/src-backend"
  mkdir -p "$d/src-backend/deploy/observability/otelcol" "$d/src-backend/deploy/helm/svp-service/templates"
  echo 'x' >"$d/src-backend/deploy/observability/otelcol/k8s-eks.yaml"
  case $v in *" nocanary "*) echo 'a: 1' ;; *) echo 'canaryPrometheus: {}' ;; esac >"$d/src-backend/deploy/helm/svp-service/values.yaml"
  case $v in *" noargs "*) echo '{"properties": {}}' ;; *) echo '{"properties": {"args": {"type": "array"}}}' ;; esac \
    >"$d/src-backend/deploy/helm/svp-service/values.schema.json"
  echo '{{- with .Values.args }}' >"$d/src-backend/deploy/helm/svp-service/templates/deployment.yaml"
  git -C "$d/src-backend" add -A
  git -C "$d/src-backend" commit -q -m chart
  R=$(git -C "$d/src-backend" rev-parse HEAD)
  git init -q -b main "$d/src-gitops"
  mkdir -p "$d/src-gitops/platforms/eks" "$d/src-gitops/argocd/apps/templates" "$d/src-gitops/envs/prd"
  case $v in *" noargmc "*) echo 'args: [serve]' ;; *) echo 'args: [mediaconvert]' ;; esac >"$d/src-gitops/platforms/eks/media-worker.yaml"
  printf '  MEDIACONVERT_QUEUE_ARN: q\n  MEDIACONVERT_ROLE_ARN: r\n  TRANSCODE_EVENTS_QUEUE_URL: u\n- cidr: {{ .vpcCidr }}, ports: [443]\n' \
    >"$d/src-gitops/platforms/eks/media-worker.values.tpl"
  case $v in
    *" nocontract "*) echo 'mediaconvertQueueArn: a' ;;
    *) printf 'mediaconvertQueueArn: a\nmediaconvertRoleArn: b\ntranscodeEventsQueueUrl: c\n' ;;
  esac \
    >"$d/src-gitops/argocd/apps/templates/applications.yaml"
  git -C "$d/src-gitops" add -A
  git -C "$d/src-gitops" commit -q -m platform
  G=$(git -C "$d/src-gitops" rev-parse HEAD)
  case $v in
    *" nopin "*) echo "revision: $R" ;;
    *) printf 'revision: %s\ngitopsRevision: %s\n' "$R" "$G" ;;
  esac >"$d/src-gitops/envs/prd/charts.yaml"
  git -C "$d/src-gitops" add -A
  git -C "$d/src-gitops" commit -q -m charts
  git clone -q "$d/src-backend" "$d/backend"
  git clone -q "$d/src-gitops" "$d/gitops"
}
prun() { SVP_BACKEND_DIR=$1/backend SVP_GITOPS_DIR=$1/gitops run promote; }
p=$work/p1
mkdir -p "$p"
build "$p"
: >"$log"
expect "promote exits 0 on a gate that passed" prun "$p"
expect "promote: clones, pins, chart, media-worker all ok, no aws call" \
  sh -c 'test "$(grep -c "^ok    " "$1")" = 5 && test ! -s "$2"' _ "$out" "$log"
expect "promote: pins print revision and gitopsRevision" sh -c 'grep -q "^ok    envs/prd/charts.yaml: revision [0-9a-f]\{40\}, gitopsRevision [0-9a-f]\{40\}$" "$1"' _ "$out"
echo dirty >>"$p/gitops/envs/prd/charts.yaml"
fails "promote: a clone with a changed tracked file" "$p/gitops has uncommitted changes" prun "$p"
expect "promote dirty: the gate is not read" sh -c '! grep -q "^ok    envs/prd" "$1"' _ "$out"
git -C "$p/gitops" checkout -q envs/prd/charts.yaml
fails "promote: a path with no clone" "$work/missing is not a git clone" renv SVP_BACKEND_DIR="$work/missing" SVP_GITOPS_DIR="$p/gitops" bash "$here/preflight.sh" promote
for variant in nopin nocanary noargmc nocontract noargs; do
  p=$work/p-$variant
  mkdir -p "$p"
  build "$p" "$variant"
  case $variant in
    nopin) want="gitopsRevision of envs/prd/charts.yaml on origin/main is '', not a commit: promote-prd has not merged" ;;
    nocanary) want='has no canaryPrometheus value' ;;
    noargmc) want="media-worker.yaml has no line 'args: .mediaconvert.'" ;;
    nocontract) want='applications.yaml has 1 of the 3 cluster-contract keys' ;;
    noargs) want='values.schema.json of svp-service does not take args as an array' ;;
  esac
  fails "promote: $variant" "$want" prun "$p"
done
# The gate is read on origin/main after a fetch: a pin merged after the clone is seen.
p=$work/p-late
mkdir -p "$p"
build "$p" nopin
printf 'revision: %s\ngitopsRevision: %s\n' "$R" "$G" >"$p/src-gitops/envs/prd/charts.yaml"
git -C "$p/src-gitops" commit -q -am pin
expect "promote: fetches origin before reading origin/main" prun "$p"

# --- plugin ---
# plugin_run VERSION: plugin with a session-manager-plugin that prints VERSION.
plugin_run() {
  fake_cmd session-manager-plugin 'echo "$FAKE_PLUGIN_VERSION"'
  : >"$log"
  renv FAKE_PLUGIN_VERSION="$1" bash "$here/preflight.sh" plugin
}
plugin_run 1.2.896.0
expect "plugin at the minimum: exits 0 and names the version" grep -q "^ok    session-manager-plugin 1.2.896.0 (at least 1.2.896)$" "$out"
expect "plugin: calls no aws" sh -c '! grep -q "^aws " "$1"' _ "$log"
expect "plugin above the minimum (1.2.1000.0, numbers not strings): exits 0" plugin_run 1.2.1000.0
expect "plugin above the minimum (1.10.0.0): exits 0" plugin_run 1.10.0.0
expect "plugin written as 1.2.896 without the fourth number: exits 0" plugin_run 1.2.896
fails "plugin 1.2.536.0 is below the minimum" 'session-manager-plugin 1.2.536.0 is below 1.2.896.*install the current package' plugin_run 1.2.536.0
fails "plugin 1.2.89.0 is below the minimum (89 is not 890)" 'session-manager-plugin 1.2.89.0 is below 1.2.896' plugin_run 1.2.89.0
fails "plugin that prints no version" "printed '', not a version number" plugin_run ""
# On PATH but failing (exit 3): reported as a failed run, not as missing.
fake_cmd session-manager-plugin 'exit 3'
fails "plugin on PATH that exits non-zero: says it failed, not that it is missing" \
  'session-manager-plugin --version failed (exit 3).*reinstall' renv bash "$here/preflight.sh" plugin
expect "plugin that exits non-zero: not reported as missing" sh -c '! grep -q "no session-manager-plugin on PATH" "$1"' _ "$err"
rm -f "$bin/session-manager-plugin"
# PATH keeps the fakes first and only the system directories after: a plugin installed on this machine is out of reach.
fails "no plugin on PATH: names the minimum and the install page" 'no session-manager-plugin on PATH.*install.*at least 1.2.896' \
  renv PATH="$bin:/usr/bin:/bin" bash "$here/preflight.sh" plugin

# --- --print ---
for args in "quotas stg" "quotas prd request" "freetier stg" "eks-upgrade prd"; do
  quotas_ok
  : >"$log"
  # shellcheck disable=SC2086
  expect "--print $args: exits 0, calls no aws, every command carries the profile and the region" \
    sh -c 'bash "$1/preflight.sh" --print $2 >"$3" 2>&1 && test ! -s "$4" && grep -q "^+ AWS_PROFILE=anhnv-[a-z]* aws " "$3" && ! grep "^+ .*aws " "$3" | grep -v -e "--region [a-z0-9-]*$"' _ "$here" "$args" "$out" "$log"
done
quotas_ok
: >"$log"
expect "--print quotas prd request: shows the request and the NodePool read" \
  sh -c 'bash "$1/preflight.sh" --print quotas prd request >"$2" 2>&1 && grep -q "request-service-quota-increase --service-code ec2 --quota-code L-1216C47A --desired-value .<14 + limits.cpu, at least 16>." "$2" && grep -q "^+ git -C .* show origin/main:platforms/eks/svp-cluster.yaml" "$2"' _ "$here" "$out"
expect "--print findings stg: three profiles, calls no aws, creates no file" \
  sh -c 'bash "$1/preflight.sh" --print findings stg >"$2" 2>&1 && test ! -s "$3" && grep -q "AWS_PROFILE=anhnv-backup-ro aws backup" "$2" && grep -q "AWS_PROFILE=anhnv-security-ro aws guardduty" "$2" && grep -q "AWS_PROFILE=anhnv-security-ro aws securityhub" "$2"' _ "$here" "$out" "$log"
expect "--print promote: shows git, calls nothing" \
  sh -c 'SVP_BACKEND_DIR=$1/backend SVP_GITOPS_DIR=$1/gitops bash "$2/preflight.sh" --print promote >"$3" 2>&1 && grep -q "^+ git -C .*gitops fetch origin" "$3"' _ "$work/p1" "$here" "$out"
expect "--print plugin: shows the version command, runs nothing" \
  sh -c 'rm -f "$3/session-manager-plugin"; bash "$1/preflight.sh" --print plugin >"$2" 2>&1 && grep -qx "+ session-manager-plugin --version" "$2"' _ "$here" "$out" "$bin"
expect "no subcommand: usage" sh -c '! bash "$1/preflight.sh" >/dev/null 2>"$2" && grep -q "^FAIL  usage:" "$2"' _ "$here" "$err"

finish
