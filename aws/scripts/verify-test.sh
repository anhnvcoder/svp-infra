#!/usr/bin/env bash
# Self-test of verify.sh against the fake aws, terraform, dig and delv: every subcommand has a run where all its checks
# are ok and runs where one check FAILs while the checks after it still run; each check runs under the profile of its
# runbook and in the region of its API, no call of aws is a write verb, nothing prints an ARN or an e-mail address.

# Usage: aws/scripts/verify-test.sh

# The fake aws answers from files named <key>, or <key>@<option>=<value> for the first of these options that the call
# has (--target-id, --filter, --bucket...) and <key>@profile=<profile>; answers hold the text the real CLI prints after
# its --query, so they are written out here as such.

# The checks run sh -c '...' with their values as arguments ($1, $2, ...): expanded by that shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=aws/scripts/testlib.sh
. "$src/testlib.sh"
fake_aws
here=$work/infra/aws/scripts
mkdir -p "$here" "$work/infra/aws/org" "$work/infra/aws/accounts/prd"
cp "$src/lib.sh" "$src/profiles.sh" "$src/verify.sh" "$here/"
out=$work/out err=$work/err profiles=$work/profiles.log
export FAKE_PROFILES=$profiles
: >"$profiles"

# The aws that picks the most specific answer file, then lets the fake of testlib.sh do the guards and the logging.
mv "$bin/aws" "$bin/aws.base"
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
key= joined= singles= prev=
for a in "$@"; do
  case $a in -*) break ;; esac
  key=${key:+${key}_}$a
done
for a in "$@"; do
  case $prev in
    --target-id | --filter | --bucket | --backup-vault-name | --topic-arn | --name | --account-id | --child-id | --role-name)
      case $a in *" "*) ;; *) joined="$joined@$prev=$a" singles="$singles $key@$prev=$a" ;; esac
      ;;
  esac
  prev=$a
done
echo "${AWS_PROFILE:-} $key" >>"$FAKE_PROFILES"
pick=
for f in "$key$joined@profile=${AWS_PROFILE:-}" "$key$joined" $singles "$key@profile=${AWS_PROFILE:-}"; do
  if [ -f "$FAKE_ANSWERS/$f" ]; then pick=$f; break; fi
done
if [ -n "$pick" ]; then
  d=$(dirname "$FAKE_ANSWERS")/refined
  mkdir -p "$d"
  rm -f "$d"/*
  cp "$FAKE_ANSWERS/$pick" "$d/$key"
  FAKE_ANSWERS=$d exec "$(dirname "$0")/aws.base" "$@"
fi
exec "$(dirname "$0")/aws.base" "$@"
EOF
chmod +x "$bin/aws"

fake_cmd terraform 'case "$*" in
  *"output -raw root_id"*) echo r-0001 ;;
  *"output -raw organization_id"*) echo o-fakeorg ;;
  *"output -json organizational_unit_ids"*) echo "{\"Prod\":\"ou-prod\",\"NonProd\":\"ou-nonprod\",\"Security\":\"ou-sec\"}" ;;
  *"output -raw zone_id"*) echo Z0FAKE ;;
  *"output -json name_servers"*) echo "[\"ns-1.awsdns.example\",\"ns-2.awsdns.example\"]" ;;
esac'
# The answers of dig by the words of the call; a file that does not exist is an empty answer.
fake_cmd dig 'case "$*" in
  "+short DS svp.example @1.1.1.1") f=ds-domain ;;
  "+dnssec SOA svp.example @1.1.1.1") f=soa-domain ;;
  "+short NS svp.example") f=ns-domain ;;
  "+norec +short DS aws.svp.example @"*) f=ds-parent ;;
  "+norec +noall +authority NS aws.svp.example @"*) f=ttl-parent ;;
  "+short NS aws.svp.example") f=ns-zone ;;
  "+noall +answer NS aws.svp.example @"*) f=ttl-zone ;;
  "+dnssec SOA aws.svp.example @"*) f=soa-prd ;;
  "+dnssec SOA stg.aws.svp.example @"*) f=soa-stg ;;
  *) f=none ;;
esac
cat "$FAKE_ANSWERS/dig-$f" 2>/dev/null || true'
fake_cmd delv 'cat "$FAKE_ANSWERS/delv" 2>/dev/null || true'

unset SVP_AWS_MGMT_ACCOUNT_ID SVP_AWS_STG_ACCOUNT_ID SVP_AWS_PRD_ACCOUNT_ID SVP_AWS_LOG_ACCOUNT_ID \
  SVP_AWS_SECURITY_ACCOUNT_ID SVP_AWS_BACKUP_ACCOUNT_ID
export SVP_AWS_MGMT_ACCOUNT_ID=000000000000 SVP_AWS_STG_ACCOUNT_ID=111111111111 SVP_AWS_PRD_ACCOUNT_ID=222222222222 \
  SVP_AWS_LOG_ACCOUNT_ID=333333333333 SVP_AWS_SECURITY_ACCOUNT_ID=444444444444 SVP_AWS_BACKUP_ACCOUNT_ID=555555555555
# stg has no Security Hub and no Config recorder; the other accounts have both.
printf '{"stg": {"managed_grafana": "session", "inspector_ecr": "off", "security_hub": "off", "config_recording": "off"}}\n' \
  >"$work/infra/aws/paid-features.json"
printf 'sso_region = "ap-northeast-1"\n' >"$work/infra/aws/org/org.auto.tfvars"
printf 'zone_name = "aws.svp.example"\n' >"$work/infra/aws/accounts/prd/prd.auto.tfvars"

run() { "$BASH" "$here/verify.sh" "$@" >"$out" 2>"$err"; }
runs_fail() { if run "$@"; then return 1; else return 0; fi; }
# okl TEXT: a line of stdout that starts with ok and TEXT. failedl TEXT: a FAIL line of stderr. noteL TEXT: likewise.
okl() { grep -q "^ok    $1" "$out"; }
notel() { grep -q "^note  $1" "$out"; }
failedl() { grep -q "^FAIL  $1" "$err"; }
under() { grep -q "^$1 $2\$" "$profiles"; }
# readonly: no call of aws in the log is a verb that writes.
readonly_log() {
  awk '$1 == "aws" && $3 ~ /^(create|put|delete|update|tag|untag|enable|disable|associate|disassociate|assume-root)/ { f = 1 }
    END { exit f }' "$log"
}
# clean: nothing on stdout or stderr is an ARN, an e-mail address or a fake endpoint of the fake aws.
clean() { ! grep -qE 'arn:aws|@[a-z0-9.-]+\.[a-z]+|fake aws' "$out" "$err"; }
ans() { printf '%b\n' "$2" >"$answers/$1"; }
reset() {
  rm -f "$answers"/*
  : >"$log"
  : >"$profiles"
}

std_arn=arn:aws:securityhub:ap-southeast-1::standards
std="$std_arn/aws-foundational-security-best-practices/v/1.0.0\tREADY\n$std_arn/cis-aws-foundations-benchmark/v/5.0.0\tREADY"
accounts='000000000000\t111111111111\t222222222222\t333333333333\t444444444444\t555555555555'
policies=organizations_list-policies-for-target

# --- org ---

org_answers() {
  reset
  ans organizations_list-accounts "$accounts"
  ans organizations_list-delegated-services-for-account \
    'guardduty.amazonaws.com\tsecurityhub.amazonaws.com\tconfig.amazonaws.com\tconfig-multiaccountsetup.amazonaws.com\taccess-analyzer.amazonaws.com\tinspector2.amazonaws.com'
  ans "$policies@--filter=SERVICE_CONTROL_POLICY" 'FullAWSAccess\tsvp-a\tsvp-b\tsvp-c\tsvp-d\tsvp-e'
  ans "$policies@--filter=RESOURCE_CONTROL_POLICY" 'RCPFullAWSAccess\tsvp-data-perimeter\tsvp-ec2-baseline\tsvp-tags'
  ans "$policies@--filter=DECLARATIVE_POLICY_EC2" 'svp-ec2-declarative'
  ans "$policies@--filter=TAG_POLICY" 'svp-tag'
  ans "$policies@--target-id=ou-prod@--filter=SERVICE_CONTROL_POLICY" 'FullAWSAccess\tsvp-prod-guardrails'
  ans iam_list-organizations-features 'RootCredentialsManagement\tRootSessions'
  ans events_describe-rule ENABLED
  ans "s3api_list-objects-v2@--bucket=svp-cloudtrail-000000000000-ap-southeast-1" '2026-11-01T00:00:00+00:00'
  ans "s3api_list-objects-v2@--bucket=svp-cloudtrail-333333333333-ap-southeast-1" \
    'AWSLogs/o-fakeorg/000000000000/\tAWSLogs/o-fakeorg/111111111111/\tAWSLogs/o-fakeorg/222222222222/\tAWSLogs/o-fakeorg/333333333333/\tAWSLogs/o-fakeorg/444444444444/\tAWSLogs/o-fakeorg/555555555555/'
  ans securityhub_list-members '000000000000\tEnabled\n222222222222\tEnabled\n333333333333\tEnabled\n555555555555\tEnabled'
  ans securityhub_get-findings 'CIS.1.1\tCIS.1.1\tIAM.3'
  ans securityhub_get-enabled-standards "$std"
  ans configservice_describe-configuration-recorders 'default\tCONTINUOUS'
  ans configservice_describe-configuration-recorder-status 'default\tTrue\tSUCCESS'
  ans cloudtrail_get-trail-status '[true, null, null]'
  ans guardduty_list-detectors det-1
  ans guardduty_describe-organization-configuration "[\"ALL\", [$(for f in S3 EKS EBS RDS LAMBDA RUNTIME; do printf '["%s", "ALL"],' "$f"; done | sed 's/,$//')]]"
  ans guardduty_list-members '000000000000\tEnabled\n111111111111\tEnabled\n222222222222\tEnabled\n333333333333\tEnabled\n555555555555\tEnabled'
  ans guardduty_list-publishing-destinations PUBLISHING
  ans accessanalyzer_list-analyzers 'svp-org\tACTIVE'
  ans securityhub_describe-organization-configuration 'CENTRAL\tENABLED'
  ans securityhub_list-configuration-policy-associations 'r-0001\tSUCCESS\n111111111111\tSUCCESS'
  # stg has config_recording off: its sources are not SUCCEEDED, and that is no error.
  ans configservice_describe-configuration-aggregator-sources-status \
    "$(for a in 000000000000 111111111111 222222222222 333333333333 444444444444 555555555555; do
      for r in ap-southeast-1 us-east-1; do
        if [ "$a" = 111111111111 ]; then printf '%s\\t%s\\tFAILED\\n' "$a" "$r"; else printf '%s\\t%s\\tSUCCEEDED\\n' "$a" "$r"; fi
      done
    done)"
  ans inspector2_describe-organization-configuration '{"ec2": false, "ecr": true, "lambda": false, "lambdaCode": false}'
  ans inspector2_batch-get-account-status \
    '444444444444\tENABLED\tDISABLED\tDISABLED\n222222222222\tENABLED\tDISABLED\tDISABLED\n333333333333\tENABLED\tDISABLED\tDISABLED\n555555555555\tENABLED\tDISABLED\tDISABLED'
  ans inspector2_list-members '222222222222\tENABLED\n333333333333\tENABLED\n555555555555\tENABLED'
}

org_answers
expect "org: exits 0 when every check is ok" run org
expect "org: 7a delegated services, 7a policies, 7b features, 7a rule, 7c trails" \
  sh -c 'for t in "7a: svp-security administers" "7a: policies of the root" "7b: RootCredentialsManagement" "7a: rule svp-security-admin-sso" "7c: the Log Archive bucket"; do grep -q "^ok    $t" "$1" || exit 1; done' _ "$out"
expect "org: 7a Security Hub members as the cost flag of stg says" okl "7a: every ACTIVE account but svp-security"
expect "org: 7a GuardDuty and Access Analyzer in both regions" \
  sh -c 'for r in ap-southeast-1 us-east-1; do grep -q "^ok    7a: GuardDuty in $r: auto-enable ALL" "$1" && grep -q "^ok    7a: Access Analyzer svp-org ACTIVE in $r" "$1" || exit 1; done' _ "$out"
expect "org: 7a Security Hub central configuration and the associations" okl "7a: Security Hub is CENTRAL ENABLED"
expect "org: 7a Config aggregator sources, stg (config_recording off) left out" okl "7a: every source of the Config aggregator"
expect "org: 7a Inspector ECR only in svp-security and three members, stg (inspector_ecr off) left out" \
  okl "7a: Inspector scans only ECR in svp-security and its 3 member"
expect "org: 7c trail svp-audit logging" okl "7c: trail svp-audit is logging"
expect "org: the trail status as anhnv-sso in the home region, the quick checks as anhnv-security-ro" \
  sh -c 'grep -q "^anhnv-sso cloudtrail_get-trail-status" "$1" && grep -q "^anhnv-security-ro guardduty_list-publishing-destinations" "$1" && grep -q "^anhnv-security-ro inspector2_list-members" "$1" && grep -q "^aws cloudtrail get-trail-status .*--region ap-southeast-1$" "$2" && grep -q "^aws accessanalyzer list-analyzers .*--region us-east-1$" "$2"' _ "$profiles" "$log"
expect "org: standards and recorder of the five profiles in two regions (stg: flags off, only a note)" \
  sh -c 'for p in anhnv-sso anhnv-security-ro anhnv-prd-ro; do for r in ap-southeast-1 us-east-1; do grep -q "^ok    $p $r: Security Hub standards" "$1" || exit 1; done; done; grep -q "^note  anhnv-stg-ro us-east-1: security_hub is off" "$1"' _ "$out"
expect "org: the FAILED controls are notes with their count" notel "7a: control CIS.1.1 FAILED in 2 finding"
expect "org: console pages and the manual assume-root are notes" \
  sh -c 'grep -q "^note  7a: Security score" "$1" && grep -q "^note  7b: the root credential audit" "$1"' _ "$out"
expect "org: no ARN, e-mail address or 12-digit account id on stdout or stderr" \
  sh -c '! grep -qE "arn:aws|[0-9]{12}" "$1" "$2"' _ "$out" "$err"
expect "org: clean output" clean
expect "org: only read verbs in the log" readonly_log
expect "org: policies read as anhnv-sso, members as anhnv-security-ro, the Log Archive trail as anhnv-log-ro" \
  sh -c 'grep -q "^anhnv-sso organizations_list-policies-for-target" "$1" && grep -q "^anhnv-security-ro securityhub_list-members" "$1" && grep -q "^anhnv-log-ro s3api_list-objects-v2" "$1"' _ "$profiles"
expect "org: standards also read as anhnv-stg-ro and anhnv-prd-ro" \
  sh -c 'grep -q "^anhnv-stg-ro securityhub_get-enabled-standards" "$1" && grep -q "^anhnv-prd-ro securityhub_get-enabled-standards" "$1"' _ "$profiles"
expect "org: Organizations, IAM in us-east-1; the rule in the region of Identity Center; trail in the home region" \
  sh -c 'grep -q "^aws iam list-organizations-features .*--region us-east-1$" "$1" && grep -q "^aws events describe-rule .*--region ap-northeast-1$" "$1" && grep -q "^aws organizations list-accounts .*--region us-east-1$" "$1" && grep -q "^aws s3api list-objects-v2 --bucket svp-cloudtrail-333333333333.*--region ap-southeast-1$" "$1" && grep -q "^aws securityhub get-enabled-standards .*--region us-east-1$" "$1"' _ "$log"
expect "org: check_account of each profile runs before its first command" \
  sh -c 'test "$(grep -c "^aws sts get-caller-identity" "$1")" = 5' _ "$log"

: >"$log"
expect "org: --print exits 0 and calls no tool" run --print org
expect "org: --print shows the commands of each profile" \
  sh -c 'grep -q "^+ AWS_PROFILE=anhnv-security-ro aws securityhub list-members" "$1" && grep -q "^+ AWS_PROFILE=anhnv-log-ro aws s3api list-objects-v2" "$1" && grep -q "^+ AWS_PROFILE=anhnv-sso terraform" "$1"' _ "$out"
expect "org: --print calls nothing" test ! -s "$log"

# FAIL paths: the check that fails is named, the checks after it still run, the exit is not 0.
org_answers
ans organizations_list-delegated-services-for-account 'guardduty.amazonaws.com\tsecurityhub.amazonaws.com'
expect "org FAIL: a missing delegated administrator exits non-zero" runs_fail org
expect "org FAIL: it names the missing principals" failedl '7a: svp-security is not the delegated administrator of: config.amazonaws.com'
expect "org FAIL: the next checks still ran" okl "7b: RootCredentialsManagement"

org_answers
ans "$policies@--filter=SERVICE_CONTROL_POLICY" 'FullAWSAccess\tsvp-a\tsvp-b'
ans iam_list-organizations-features 'RootSessions'
expect "org FAIL: SCPs and root features wrong exits non-zero" runs_fail org
expect "org FAIL: it names the SCPs" failedl "7a: root SCPs are"
expect "org FAIL: it names the missing root feature" failedl '7b: organization root features lack: RootCredentialsManagement'

org_answers
ans securityhub_list-members '000000000000\tEnabled\n111111111111\tEnabled\n222222222222\tEnabled\n333333333333\tEnabled'
expect "org FAIL: stg a member although security_hub is off, backup not a member" runs_fail org
expect "org FAIL: it names both by their last 4 digits only" \
  sh -c 'grep -q "^FAIL  7a: Security Hub member status wrong for: ...1111(security_hub off) ...5555" "$1" && ! grep -qE "[0-9]{8}" "$1"' _ "$err"

org_answers
ans "s3api_list-objects-v2@--bucket=svp-cloudtrail-333333333333-ap-southeast-1" 'AWSLogs/o-fakeorg/000000000000/\tAWSLogs/o-fakeorg/111111111111/'
expect "org FAIL: an account without logs in the Log Archive bucket" runs_fail org
expect "org FAIL: it names the accounts by their last 4 digits" failedl '7c: no CloudTrail logs in the Log Archive bucket for: ...2222 ...3333 ...4444 ...5555'

org_answers
ans "securityhub_get-enabled-standards@profile=anhnv-security-ro" "$std_arn/cis-aws-foundations-benchmark/v/5.0.0\tREADY"
expect "org FAIL: one standard of two READY at anhnv-security-ro" runs_fail org
expect "org FAIL: it names the profile, the region and the count" failedl 'anhnv-security-ro ap-southeast-1: 1 of the 2 standards'
expect "org FAIL: the other profiles still ran" okl "anhnv-prd-ro us-east-1: Security Hub standards"

org_answers
SVP_AWS_LOG_ACCOUNT_ID=999999999999 expect "org FAIL: a profile in another account exits non-zero" runs_fail org
expect "org FAIL: that profile stops its own checks only" \
  sh -c 'grep -q "^FAIL  profile anhnv-log-ro is account" "$1" && grep -q "^ok    7b: " "$2" && ! grep -q "^anhnv-log-ro s3api" "$3"' _ "$err" "$out" "$profiles"

org_answers
rm "$work/infra/aws/org/org.auto.tfvars"
expect "org FAIL: no org.auto.tfvars for sso_region" runs_fail org
expect "org FAIL: it names the file and the other checks still ran" \
  sh -c 'grep -q "^FAIL  no .*org.auto.tfvars" "$1" && grep -q "^ok    7b: " "$2"' _ "$err" "$out"
printf 'sso_region = "ap-northeast-1"\n' >"$work/infra/aws/org/org.auto.tfvars"

org_answers
rm "$answers/events_describe-rule"
expect "org FAIL: the rule absent from the region of Identity Center" runs_fail org
expect "org FAIL: it says sso_region is wrong" failedl '7a: rule svp-security-admin-sso not found in ap-northeast-1'

org_answers
ans cloudtrail_get-trail-status '[true, "AccessDenied", null]'
ans guardduty_list-members '000000000000\tEnabled\n222222222222\tEnabled'
ans guardduty_list-publishing-destinations 'PUBLISHING\tSTOPPED'
ans accessanalyzer_list-analyzers ''
expect "org FAIL: trail delivery error, GuardDuty members and analyzer wrong exits non-zero" runs_fail org
expect "org FAIL: it names the delivery error" failedl '7c: trail svp-audit is \[true,"AccessDenied",null\]'
expect "org FAIL: it names the GuardDuty members missing by their last 4 digits" \
  failedl '7a: GuardDuty in ap-southeast-1: not an Enabled member: ...1111 ...3333 ...5555'
expect "org FAIL: it names the analyzer" failedl '7a: no ACTIVE organization analyzer svp-org in us-east-1'
expect "org FAIL: Inspector still checked" okl "7a: Inspector scans only ECR"

org_answers
ans guardduty_list-publishing-destinations 'PUBLISHING\tSTOPPED'
expect "org FAIL: a publishing destination STOPPED" runs_fail org
expect "org FAIL: it names the publishing destinations" failedl "7a: GuardDuty in us-east-1: publishing destinations"

org_answers
ans securityhub_list-configuration-policy-associations 'r-0001\tPENDING\n111111111111\tFAILED'
ans configservice_describe-configuration-aggregator-sources-status '222222222222\tus-east-1\tFAILED\n111111111111\tus-east-1\tFAILED'
ans inspector2_list-members '111111111111\tENABLED\n222222222222\tENABLED\n333333333333\tENABLED\n555555555555\tENABLED'
ans inspector2_describe-organization-configuration '{"ec2": true, "ecr": true, "lambda": false, "lambdaCode": false}'
expect "org FAIL: an association, an aggregator source and Inspector wrong exits non-zero" runs_fail org
expect "org FAIL: it names the account association that failed" \
  failedl '7a: Security Hub configuration policy association not SUCCESS for: ...1111(FAILED)'
expect "org FAIL: it names the aggregator source, not the one of config_recording off" \
  sh -c 'grep -q "^FAIL  7a: Config aggregator sources not SUCCEEDED: ...2222/us-east-1(FAILED) (" "$1"' _ "$err"
expect "org FAIL: it names the auto-enable of Inspector" failedl '7a: Inspector auto-enables'
org_answers
ans securityhub_list-configuration-policy-associations 'r-0001\tPENDING\n111111111111\tSUCCESS'
ans inspector2_list-members '111111111111\tENABLED\n222222222222\tENABLED\n333333333333\tENABLED\n555555555555\tENABLED'
expect "org FAIL: an account with inspector_ecr off is a member" runs_fail org
expect "org FAIL: it names it" failedl '7a: Inspector wrong for: ...1111(inspector_ecr off but a member)'
expect "org: a PENDING association is a note, not a FAIL" \
  sh -c 'grep -q "^note  7a: Security Hub association PENDING for: root" "$1" && grep -q "^ok    7a: Security Hub is CENTRAL ENABLED" "$1"' _ "$out"

org_answers
SVP_AWS_MGMT_ACCOUNT_ID=999999999999 expect "org FAIL: anhnv-sso in another account exits non-zero" runs_fail org
expect "org FAIL: the checks that need its lists say so, none dies on an unset variable" \
  sh -c 'grep -q "^FAIL  7a: no list of accounts" "$1" && grep -q "^FAIL  7c: no organization id" "$1" && ! grep -q "unbound variable" "$1" && grep -q "check(s) failed, each named above" "$1"' _ "$err"

# --- backup ---

backup_answers() {
  reset
  ans organizations_list-parents ou-sec
  ans organizations_describe-account 'svp-backup\tACTIVE'
  ans account_get-alternate-contact 'SECURITY\tSecurity Contact'
  ans backup_describe-global-settings '{"isCrossAccountBackupEnabled": "true", "isMpaEnabled": "false"}'
  ans backup_describe-region-settings 'True\tTrue'
  ans "$policies@--target-id=ou-prod@--filter=BACKUP_POLICY" 'svp-backup-prd'
  ans "$policies@--target-id=ou-nonprod@--filter=BACKUP_POLICY" 'svp-backup-stg'
  ans "organizations_describe-effective-policy@--target-id=111111111111" '{"plans": {"svp-stg": {}}}'
  ans "organizations_describe-effective-policy@--target-id=222222222222" '{"plans": {"svp-prd": {}}}'
  ans securityhub_get-enabled-standards "$std"
  ans configservice_describe-configuration-recorders 'default\tCONTINUOUS'
  ans configservice_describe-configuration-recorder-status 'default\tTrue\tSUCCESS'
  ans guardduty_list-detectors det-1
  ans guardduty_list-members Enabled
  ans securityhub_list-members Enabled
  ans inspector2_batch-get-account-status 'ENABLED\tDISABLED\tDISABLED'
  local e
  for e in stg prd; do
    ans "backup_list-backup-plans@profile=anhnv-$e-ro" "plan-$e"
    ans "backup_get-backup-plan@profile=anhnv-$e-ro" "daily\tsvp-$e\tcron(0 5 * * ? *)\t7\t35"
    ans "backup_list-backup-selections@profile=anhnv-$e-ro" "svp-$e-tagged"
    ans "backup_describe-backup-vault@--backup-vault-name=svp-$e" "svp-$e\tFalse\t0"
    ans "backup_describe-backup-vault@--backup-vault-name=svp-$e-copy" "svp-$e-copy\tTrue\t7\t35"
    ans "backup_get-backup-vault-access-policy@--backup-vault-name=svp-$e-copy" \
      "$(copy_policy "$(if [ "$e" = stg ]; then echo 111111111111; else echo 222222222222; fi)")"
    ans "iam_list-attached-role-policies@--role-name=svp-$e-backup" 'PolicyA\tPolicyB\tPolicyC\tPolicyD'
  done
}
# copy_policy ACCOUNT: the access policy of a copy vault, a single Allow from the root of ACCOUNT.
copy_policy() {
  printf '{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "backup:CopyIntoBackupVault", "Resource": "*", "Principal": {"AWS": "arn:aws:iam::%s:root"}}]}' "$1"
}

backup_answers
expect "backup: exits 0 when every check is ok" run backup
expect "backup: 7a OU, name, status and contact" okl "7a: svp-backup is ACTIVE in the OU Security"
expect "backup: 7a detection services at the delegated admin, both GuardDuty regions" \
  sh -c 'grep -q "^ok    7a: svp-backup is a GuardDuty member in ap-southeast-1" "$1" && grep -q "^ok    7a: svp-backup is a GuardDuty member in us-east-1" "$1" && grep -q "^ok    7a: svp-backup is a Security Hub member" "$1"' _ "$out"
expect "backup: 7b global settings and the opt-in of three profiles" \
  sh -c 'grep -q "^ok    7b: cross-account" "$1" && for p in anhnv-sso anhnv-stg-ro anhnv-prd-ro; do grep -q "^ok    7b: $p: RDS and S3" "$1" || exit 1; done' _ "$out"
expect "backup: 7c policies, plans, selections, vaults of both envs" \
  sh -c 'for e in stg prd; do grep -q "^ok    7c: .*svp-backup-$e" "$1" && grep -q "^ok    7c: the plan svp-$e has the rule daily" "$1" && grep -q "^ok    7c: the vault svp-$e is not locked" "$1" || exit 1; done' _ "$out"
expect "backup: 7d copy vaults of both envs" \
  sh -c 'for e in stg prd; do grep -q "^ok    7d: the vault svp-$e-copy is locked" "$1" || exit 1; done' _ "$out"
expect "backup: the schedule and the retention are notes for the eye" notel "7c: stg rule schedule and retention"
expect "backup: baseline of svp-backup at anhnv-backup-ro" okl "anhnv-backup-ro us-east-1: Security Hub standards"
expect "backup: no ARN or 12-digit account id printed" sh -c '! grep -qE "arn:aws|[0-9]{12}" "$1" "$2"' _ "$out" "$err"
expect "backup: clean output" clean
expect "backup: only read verbs in the log" readonly_log
expect "backup: each check under its runbook profile" \
  sh -c 'grep -q "^anhnv-sso backup_describe-global-settings" "$1" && grep -q "^anhnv-backup-ro backup_describe-backup-vault" "$1" && grep -q "^anhnv-security-ro guardduty_list-members" "$1" && grep -q "^anhnv-stg-ro backup_get-backup-plan" "$1" && grep -q "^anhnv-prd-ro backup_get-backup-plan" "$1"' _ "$profiles"
expect "backup: regions: Backup in the home region, Organizations, account and IAM in us-east-1" \
  sh -c 'grep -q "^aws backup describe-global-settings .*--region ap-southeast-1$" "$1" && grep -q "^aws organizations list-parents .*--region us-east-1$" "$1" && grep -q "^aws account get-alternate-contact .*--region us-east-1$" "$1" && grep -q "^aws iam list-attached-role-policies .*--region us-east-1$" "$1"' _ "$log"
: >"$log"
expect "backup: --print exits 0 and calls no tool" run --print backup
expect "backup: --print calls nothing" test ! -s "$log"

backup_answers
ans backup_describe-global-settings '{"isCrossAccountBackupEnabled": "true", "isMpaEnabled": "true"}'
ans "backup_describe-region-settings@profile=anhnv-prd-ro" 'True\tFalse'
expect "backup FAIL: global settings and an opt-in wrong exits non-zero" runs_fail backup
expect "backup FAIL: it names the settings" failedl '7b: AWS Backup global settings'
expect "backup FAIL: it names the profile of the opt-in" failedl '7b: anhnv-prd-ro: opt-in of RDS and S3'
expect "backup FAIL: the later checks still ran" okl "7d: the vault svp-prd-copy"

backup_answers
ans organizations_list-parents ou-other
ans "backup_list-backup-plans@profile=anhnv-stg-ro" None
expect "backup FAIL: wrong OU and no generated plan in stg exits non-zero" runs_fail backup
expect "backup FAIL: it names the OU" failedl '7a: svp-backup is not in the OU Security'
expect "backup FAIL: it says AWS has not generated the plan" failedl '7c: AWS has not generated the plan svp-stg'
expect "backup FAIL: the prd plan still checked" okl "7c: the plan svp-prd has the rule daily"

backup_answers
ans "backup_get-backup-vault-access-policy@--backup-vault-name=svp-prd-copy" "$(copy_policy 999999999999)"
ans inspector2_batch-get-account-status 'ENABLED\tENABLED\tDISABLED'
expect "backup FAIL: a copy vault open to another account and Inspector wrong exits non-zero" runs_fail backup
expect "backup FAIL: it names the vault" failedl '7d: the access policy of svp-prd-copy'
expect "backup FAIL: it names Inspector" failedl '7a: Inspector of svp-backup'
expect "backup FAIL: the stg copy vault still ok" okl "7d: the vault svp-stg-copy"

backup_answers
ans guardduty_list-members ''
SVP_AWS_BACKUP_ACCOUNT_ID=999999999999 expect "backup FAIL: a profile in another account exits non-zero" runs_fail backup
expect "backup FAIL: it is named and its checks skipped" \
  sh -c 'grep -q "^FAIL  profile anhnv-backup-ro is account" "$1" && ! grep -q "^anhnv-backup-ro backup_" "$2"' _ "$err" "$profiles"
backup_answers
ans guardduty_list-members ''
expect "backup FAIL: GuardDuty without the member says to wait" runs_fail backup
expect "backup FAIL: it names the region and the 24 hours" failedl '7a: GuardDuty member status of svp-backup in ap-southeast-1 is .none. (a new account takes up to 24 h)'

# --- subscriptions ---

sub_answers() {
  reset
  ans "sns_list-subscriptions-by-topic@--topic-arn=arn:aws:sns:ap-southeast-1:111111111111:svp-stg-alarms" \
    'arn:aws:sns:ap-southeast-1:111111111111:svp-stg-alarms:aaaa'
  ans "sns_list-subscriptions-by-topic@--topic-arn=arn:aws:sns:ap-southeast-1:444444444444:svp-security-alarms" \
    'arn:aws:sns:ap-southeast-1:444444444444:svp-security-alarms:bbbb'
  ans "sns_list-subscriptions-by-topic@--topic-arn=arn:aws:sns:us-east-1:222222222222:svp-prd-dns-alarms" \
    'arn:aws:sns:us-east-1:222222222222:svp-prd-dns-alarms:cccc'
  ans "sns_list-subscriptions-by-topic@--topic-arn=arn:aws:sns:ap-southeast-1:222222222222:svp-prd-alarms" \
    'arn:aws:sns:ap-southeast-1:222222222222:svp-prd-alarms:dddd'
  ans sns_list-topics 1
}
sub_answers
expect "subscriptions stg: exits 0 when confirmed" run subscriptions stg
expect "subscriptions stg: the topic is confirmed" okl "topic svp-stg-alarms: every subscription is confirmed"
expect "subscriptions stg: read as anhnv-stg in the home region" \
  sh -c 'grep -q "^anhnv-stg sns_list-subscriptions-by-topic" "$1" && grep -q "^aws sns list-subscriptions-by-topic .*--region ap-southeast-1$" "$2"' _ "$profiles" "$log"
expect "subscriptions stg: clean output (no ARN, no e-mail address)" clean
expect "subscriptions stg: only read verbs" readonly_log
expect "subscriptions mgmt: exits 0" run subscriptions mgmt
expect "subscriptions mgmt: the security topic is read as anhnv-security-ro" \
  sh -c 'grep -q "^ok    topic svp-security-alarms" "$1" && grep -q "^anhnv-security-ro sns_list" "$2"' _ "$out" "$profiles"
: >"$profiles"
expect "subscriptions prd: exits 0" run subscriptions prd
expect "subscriptions prd: both topics, the DNS one in us-east-1, as anhnv-prd" \
  sh -c 'grep -q "^ok    topic svp-prd-dns-alarms" "$1" && grep -q "^ok    topic svp-prd-alarms" "$1" && grep -q "^aws sns list-subscriptions-by-topic .*--region us-east-1$" "$2" && test "$(grep -c "^anhnv-prd sns_list-subscriptions" "$3")" = 2' _ "$out" "$log" "$profiles"

sub_answers
ans sns_list-topics 0
expect "subscriptions prd between sessions: exits 0" run subscriptions prd
expect "subscriptions prd between sessions: the DNS topic checked, the session topic skipped" \
  sh -c 'grep -q "^ok    topic svp-prd-dns-alarms" "$1" && grep -q "^skip  topic svp-prd-alarms does not exist: its session root is not applied" "$1"' _ "$out"
expect "subscriptions prd between sessions: the session topic looked up in the home region" \
  sh -c 'grep -q "^aws sns list-topics .*--region ap-southeast-1$" "$1" && ! grep -q "svp-prd-alarms --query" "$1"' _ "$log"

sub_answers
ans "sns_list-subscriptions-by-topic@--topic-arn=arn:aws:sns:us-east-1:222222222222:svp-prd-dns-alarms" \
  'PendingConfirmation'
expect "subscriptions FAIL: a pending subscription exits non-zero" runs_fail subscriptions prd
expect "subscriptions FAIL: it names the topic and not the e-mail address or ARN" \
  sh -c 'grep -q "^FAIL  topic svp-prd-dns-alarms: a subscription is still PendingConfirmation" "$1" && ! grep -qE "arn:|@" "$1"' _ "$err"
expect "subscriptions FAIL: the other topic of prd still checked" okl "topic svp-prd-alarms"
sub_answers
rm "$answers"/sns_list-subscriptions-by-topic@*stg-alarms
expect "subscriptions FAIL: a topic that cannot be read exits non-zero" runs_fail subscriptions stg
expect "subscriptions FAIL: it names the topic" failedl 'topic svp-stg-alarms cannot be read in ap-southeast-1'
sub_answers
ans "sns_list-subscriptions-by-topic@--topic-arn=arn:aws:sns:ap-southeast-1:111111111111:svp-stg-alarms" None
expect "subscriptions FAIL: a topic without subscription exits non-zero" runs_fail subscriptions stg
expect "subscriptions FAIL: it says the apply creates it" failedl 'topic svp-stg-alarms has no subscription'
expect "subscriptions: an unknown environment is refused" runs_fail subscriptions qa
: >"$log"
expect "subscriptions: --print calls no tool" run --print subscriptions stg
expect "subscriptions: --print calls nothing" test ! -s "$log"

# --- dnssec ---

# A SHA-256 digest is 64 hex digits; dig +short prints it as two words (56 and 8), DSRecord as one.
digest=0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
ds="12345 13 2 $digest"
dnssec_answers() {
  reset
  ans route53_get-dnssec '{"Status": {"ServeSignature": "SIGNING"}, "KeySigningKeys": [{"Name": "svp_prd_ksk", "Status": "ACTIVE", "DSRecord": "'"$ds"'"}]}'
  ans dig-ds-domain '6789 13 2 FEDCBA987654'
  ans dig-soa-domain ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0'
  ans dig-ns-domain 'ns1.pns.example.'
  ans dig-ds-parent "$(printf '12345 13 2 %s %s' "${digest:0:56}" "${digest:56}" | tr '[:upper:]' '[:lower:]')"
  ans dig-ttl-parent 'aws.svp.example.\t300\tIN\tNS\tns-1.awsdns.example.'
  ans dig-ns-zone 'ns-1.awsdns.example.'
  ans dig-ttl-zone 'aws.svp.example.\t3600\tIN\tNS\tns-1.awsdns.example.'
  ans dig-soa-prd ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 2\n;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2'
  ans dig-soa-stg ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 3\n;; flags: qr rd ra; QUERY: 1, ANSWER: 1'
  ans delv '; fully validated'
}
dnssec_answers
expect "dnssec: exits 0 when the zone is signed, the chain valid and resolvers validate" run dnssec
expect "dnssec: signing and KSK" okl "zone aws.svp.example is SIGNING and its KSK svp_prd_ksk is ACTIVE"
expect "dnssec: the DS of the parent domain validates and the DS of the zone is at the parent" \
  sh -c 'grep -q "^ok    svp.example has a DS at 1.1.1.1 and validates" "$1" && grep -q "^ok    the DS of aws.svp.example at the parent is the DSRecord" "$1"' _ "$out"
expect "dnssec: both resolvers, prd validated, stg not" \
  sh -c 'for r in 1.1.1.1 8.8.8.8; do grep -q "^ok    aws.svp.example at $r: NOERROR, ad" "$1" && grep -q "^ok    stg.aws.svp.example at $r: NOERROR, noad" "$1" || exit 1; done' _ "$out"
expect "dnssec: delv fully validated" okl "delv: aws.svp.example is fully validated"
expect "dnssec: the NS records for Cloudflare are notes" \
  sh -c 'grep -q "^note  Cloudflare: NS record, name aws, value ns-1.awsdns.example" "$1" && grep -q "^note  Cloudflare: NS record, name aws, value ns-2.awsdns.example" "$1"' _ "$out"
expect "dnssec: the DS record for Cloudflare is a note with its four fields" \
  notel "Cloudflare: DS record, name aws, key tag 12345, algorithm 13, digest type 2, digest $digest\$"
expect "dnssec: the NS TTLs of 3e are a note" \
  notel '3e: NS TTL 300 s at the parent, 3600 s at the zone (3600 after 2a): wait 10 minutes plus the larger before 3f'
expect "dnssec: the DS of the registrar is shown with its four fields" \
  notel 'registrar: DS of svp.example is key tag 6789, algorithm 13, digest type 2, digest FEDCBA987654'
expect "dnssec: signing is read as anhnv-prd in us-east-1" \
  sh -c 'grep -q "^anhnv-prd route53_get-dnssec" "$1" && grep -q "^aws route53 get-dnssec .*--region us-east-1$" "$2"' _ "$profiles" "$log"
expect "dnssec: only read verbs, clean output" sh -c '! grep -qE "arn:aws" "$1" "$2"' _ "$out" "$err"
expect "dnssec: read verbs only in the log" readonly_log
: >"$log"
expect "dnssec: --print exits 0" run --print dnssec
expect "dnssec: --print shows dig and calls no tool" sh -c 'grep -q "^+ dig +dnssec SOA aws.svp.example @1.1.1.1" "$1" && test ! -s "$2"' _ "$out" "$log"

dnssec_answers
ans route53_get-dnssec '{"Status": {"ServeSignature": "NOT_SIGNING"}, "KeySigningKeys": []}'
expect "dnssec FAIL: an unsigned zone exits non-zero" runs_fail dnssec
expect "dnssec FAIL: it names step (2) of edge-setup.md" failedl 'zone aws.svp.example is not signed .status .NOT_SIGNING.): apply aws/accounts/prd, step (2) of edge-setup.md'
expect "dnssec FAIL: the dig checks still ran" okl "aws.svp.example at 8.8.8.8: NOERROR, ad"

dnssec_answers
rm "$answers/dig-ds-domain"
ans dig-soa-domain ';; flags: qr rd ra; QUERY: 1'
expect "dnssec FAIL: no DS of the parent domain exits non-zero" runs_fail dnssec
expect "dnssec FAIL: it names step 3a" failedl 'no DS for svp.example at 1.1.1.1.*3a of edge-setup.md'

dnssec_answers
ans dig-ds-parent '99999 13 2 0000'
expect "dnssec FAIL: another DS at the parent exits non-zero" runs_fail dnssec
expect "dnssec FAIL: it names step 3d" failedl 'the DS of aws.svp.example at Cloudflare differs from the KSK.s DSRecord: fix it (3d of edge-setup.md)'
dnssec_answers
rm "$answers/dig-ds-parent"
expect "dnssec FAIL: no DS at the parent's name server" runs_fail dnssec
expect "dnssec FAIL: it says to add it" failedl "no DS aws.svp.example at the parent's name server: add it at Cloudflare"

dnssec_answers
ans dig-soa-prd ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 2\n;; flags: qr rd ra; QUERY: 1'
ans dig-soa-stg ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 3\n;; flags: qr rd ra ad; QUERY: 1'
expect "dnssec FAIL: SERVFAIL for prd and a validated stg zone exit non-zero" runs_fail dnssec
expect "dnssec FAIL: it points to the rollback" failedl 'aws.svp.example at 1.1.1.1 answers .SERVFAIL.: if SERVFAIL, do the rollback'
expect "dnssec FAIL: it names the stg zone that validates" failedl 'stg.aws.svp.example at 8.8.8.8 is validated'
dnssec_answers
ans delv 'resolution failed: SERVFAIL'
expect "dnssec FAIL: delv without full validation exits non-zero" runs_fail dnssec
expect "dnssec FAIL: it names delv" failedl 'delv does not report aws.svp.example fully validated'
dnssec_answers
ans delv ';; validating aws.svp.example/SOA: no valid signature found (unsupported algorithm)'
expect "dnssec: delv without the algorithm is a note, the dig checks stand" run dnssec
expect "dnssec: the note says the dig checks are enough" notel 'delv lacks an algorithm of aws.svp.example'

# farm [dig] [delv]: a PATH with the tools the script needs and the fakes, without dig or delv unless asked for.
farm() {
  local t
  rm -rf "$work/farm"
  mkdir -p "$work/farm"
  for t in awk sed tr jq grep head sort uniq cat date mktemp dirname basename env mkdir rm cp mv cmp wc cut tee ls touch \
    chmod readlink uname sleep; do
    ln -s "$(command -v "$t")" "$work/farm/$t"
  done
  ln -s "$BASH" "$work/farm/bash"
  for t in aws aws.base terraform "$@"; do ln -s "$bin/$t" "$work/farm/$t"; done
}
dnssec_answers
farm
expect "dnssec FAIL: no dig exits non-zero" sh -c '! PATH=$1 "$2" "$3" dnssec >"$4" 2>"$5"' _ "$work/farm" "$BASH" "$here/verify.sh" "$out" "$err"
expect "dnssec FAIL: it names dig" failedl 'dig is not installed'
expect "dnssec FAIL: no aws call before it" test ! -s "$log"
farm dig
expect "dnssec: without delv the dig checks stand and a note says so" \
  sh -c 'PATH=$1 "$2" "$3" dnssec >"$4" 2>"$5" && grep -q "^note  delv is not installed" "$4"' _ "$work/farm" "$BASH" "$here/verify.sh" "$out" "$err"

# --- cost ---

cost_answers() {
  reset
  ans ce_get-cost-and-usage '{"ResultsByTime": [{"TimePeriod": {"Start": "2026-11-08", "End": "2026-11-09"}, "Groups": [{"Keys": ["Amazon GuardDuty"], "Metrics": {"UnblendedCost": {"Amount": "0.5000", "Unit": "USD"}}}, {"Keys": ["AWS Config"], "Metrics": {"UnblendedCost": {"Amount": "0.2500", "Unit": "USD"}}}]}]}'
}
# run_today ARGS...: run, with today the UTC date of the run; a run across 00:00 UTC runs once more.
run_today() {
  local t0 rc=0
  t0=$(date -u +%Y-%m-%d)
  run "$@" || rc=$?
  today=$(date -u +%Y-%m-%d)
  if [ "$t0" != "$today" ]; then
    rc=0
    run "$@" || rc=$?
  fi
  return "$rc"
}
today=$(date -u +%Y-%m-%d)
cost_answers
expect "cost mgmt: exits 0 with the rows by service" run_today cost mgmt 2026-11-08
expect "cost mgmt: a note per service and day, then the total" \
  sh -c 'grep -q "^note  2026-11-08  Amazon GuardDuty  0.5000 USD" "$1" && grep -q "^ok    2 row(s) from 2026-11-08 to '"$today"', 0.7500 USD" "$1"' _ "$out"
expect "cost mgmt: the filter is the six services, in us-east-1, as anhnv-sso" \
  sh -c 'grep -q "^aws ce get-cost-and-usage .*--time-period Start=2026-11-08,End='"$today"' .*AWS CloudTrail.*--region us-east-1$" "$1" && grep -q "^anhnv-sso ce_get-cost-and-usage" "$2"' _ "$log" "$profiles"
expect "cost mgmt: the console pages are notes" notel "GuardDuty and Security Hub estimated cost after the trial"
expect "cost mgmt: only read verbs, clean output" sh -c '! grep -qE "arn:aws|[0-9]{12}" "$1" "$2"' _ "$out" "$err"
expect "cost mgmt: read verbs only" readonly_log
cost_answers
expect "cost stg: exits 0" run_today cost stg
expect "cost stg: read as anhnv-stg with no filter, the default start seven days back" \
  sh -c 'grep -q "^anhnv-stg ce_get-cost-and-usage" "$1" && ! grep -q -- "--filter" "$2" && grep -q "Start=[0-9]\{4\}-[0-9][0-9]-[0-9][0-9],End='"$today"' " "$2"' _ "$profiles" "$log"
cost_answers
expect "cost prd: exits 0" run cost prd
expect "cost prd: read as anhnv-prd" under anhnv-prd ce_get-cost-and-usage
cost_answers
expect "cost backup: exits 0" run cost backup 2026-11-08
expect "cost backup: read as anhnv-sso, filtered on the backup account" \
  sh -c 'grep -q "^anhnv-sso ce_get-cost-and-usage" "$1" && grep -q "LINKED_ACCOUNT.*555555555555" "$2"' _ "$profiles" "$log"
expect "cost backup: the backup account id is not printed" no_leak 555555555555 "$out" "$err"

cost_answers
rm "$answers/ce_get-cost-and-usage"
expect "cost FAIL: a failing query exits non-zero" runs_fail cost mgmt 2026-11-08
expect "cost FAIL: it says how to turn Cost Explorer on" failedl 'ce get-cost-and-usage (first use: turn Cost Explorer on once'
cost_answers
ans ce_get-cost-and-usage '{"ResultsByTime": [{"TimePeriod": {"Start": "2026-11-08", "End": "2026-11-09"}, "Groups": []}]}'
expect "cost: no rows yet is a note, not a FAIL" run cost mgmt 2026-11-08
expect "cost: the note says Cost Explorer lags" notel "no cost data from 2026-11-08"
expect "cost FAIL: a START that is not a date" runs_fail cost mgmt yesterday
# fails_today: cost mgmt with START the UTC date of the run fails; a run across 00:00 UTC runs again with the new date.
fails_today() {
  local t0
  t0=$(date -u +%Y-%m-%d)
  runs_fail cost mgmt "$t0" && [ "$t0" = "$(date -u +%Y-%m-%d)" ] && return 0
  runs_fail cost mgmt "$(date -u +%Y-%m-%d)"
}
expect "cost FAIL: a START that is today" fails_today
SVP_AWS_BACKUP_ACCOUNT_ID='' expect "cost FAIL: backup without its account variable" runs_fail cost backup 2026-11-08
SVP_AWS_STG_ACCOUNT_ID=999999999999 expect "cost FAIL: a profile in another account" runs_fail cost stg 2026-11-08
: >"$log"
expect "cost: --print exits 0" run --print cost mgmt 2026-11-08
expect "cost: --print calls nothing" test ! -s "$log"

# --- usage ---

expect "no subcommand is refused" runs_fail
expect "an unknown subcommand is refused" runs_fail nothing
expect "cost without an environment is refused" runs_fail cost
finish
