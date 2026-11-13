#!/usr/bin/env bash
# The restore drills of a session and the backup cleanup before the destroy of root env. backup checks what the daily
# plan of the organization's backup policy relies on in the account (plan svp-<env>, its selection, the opt-in of RDS
# and S3), backs the DB instance and both buckets up on demand into vault svp-<env>, copies each recovery point to vault
# svp-<env>-copy of account svp-backup and writes the session's recovery points, restore-drill-points.tsv.

# rds restores svp-<env> to svp-<env>-pitr at a fixed time T_r and compares the data of both through svp-pg; s3 deletes
# one object of the media bucket and restores it from the session's recovery point of that bucket; both then measure
# RTO and RPO against the targets. Results in $SVP_SESSION_DIR/restore-drill.tsv, times in UTC.

# cleanup runs after the last apply of root env and just before tf.sh <env> env plan --destroy: it deletes
# svp-<env>-pitr, removes tag Backup from the instance and the buckets, waits for every job of the account, and deletes
# each recovery point of vault svp-<env> that has a completed copy (the source's keys go with the destroy). It records
# backup-drained, which tf.sh needs before that destroy; backup, rds and s3 record backup-undrained first.

# Design notes: README.md.

# Usage: aws/scripts/restore-drill.sh [--print] stg|prd backup|rds|s3|cleanup
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
usage="usage: $(basename "$0") [--print] $(env_names session) backup|rds|s3|cleanup"
[ $# -eq 2 ] || fail "$usage"
env_arg "$1"
cmd=$2
case $cmd in
  backup | rds | s3 | cleanup) ;;
  *) fail "$usage" ;;
esac
session_dir

tab=$'\t'
account=${!account_var:-}
if printing && [ -z "$account" ]; then account="<$account_var>"; fi
db=svp-$env_name
pitr=$db-pitr
vault=$db
role_arn=arn:aws:iam::$account:role/$db-backup
db_arn=arn:aws:rds:$region:$account:db:$db
uploads=$db-uploads-$account-$region
media=$db-media-$account-$region
points=$session/restore-drill-points.tsv
results=$session/restore-drill.tsv

# Limits of the waits in seconds (the self-test sets one for all of them), then the RTO and RPO targets of the drills.
job_limit=${SVP_DRILL_LIMIT:-3600}
lrt_limit=${SVP_DRILL_LIMIT:-900}
pitr_limit=${SVP_DRILL_LIMIT:-3600}
pitr_delete_limit=${SVP_DRILL_LIMIT:-1800}
restore_limit=${SVP_DRILL_LIMIT:-1800}
rds_rto_target=3600
rds_rpo_target=300
s3_rto_target=1800

# The states of a job that has not ended, as the API of each kind names them.
backup_running='CREATED PENDING RUNNING ABORTING'
copy_running='CREATED RUNNING'
restore_running='PENDING RUNNING'

# The tables the migrations of each service create (services/<service>/migrations/ of the code repository): a table a
# new migration adds goes here too. goose keeps its version table in schema goose: it records migrations, not data.
tables='video videos
video outbox
engagement likes
engagement like_counts
engagement view_counts
engagement consumer_offsets
feed follows
feed videos
feed timeline'

# jq's fromdateiso8601 takes a UTC time with Z alone; the CLI prints times with an offset and fractions of a second.
# shellcheck disable=SC2016 # $c is jq's
jq_defs='def epoch: sub("\\.[0-9]+"; "") | capture("^(?<t>.{19})(?<z>Z|[+-][0-9]{2}:[0-9]{2})$") as $c
  | ($c.t + "Z" | fromdateiso8601)
    - (if $c.z == "Z" then 0 else ($c.z[1:3] | tonumber) * 3600 + ($c.z[4:6] | tonumber) * 60
       | if $c.z[0:1] == "-" then -. else . end end);'

# q FILTER PLACEHOLDER AWS-ARGS...: what jq's FILTER (with epoch above) makes of the JSON answer of aws AWS-ARGS;
# PLACEHOLDER with --print, which calls nothing.
q() {
  local filter=$1 placeholder=$2 out
  shift 2
  out=$(aws_ "$@" --output json </dev/null) || return 1
  if printing; then
    printf '%s\n' "$placeholder"
    return 0
  fi
  jq -r "$jq_defs $filter" <<<"$out"
}

# utc EPOCH: the time as RFC 3339 in UTC; to_epoch TIME: the other way, for a time the CLI printed.
utc() { jq -nr --argjson e "$1" '$e | todate'; }
to_epoch() { jq -nr --arg t "$1" "$jq_defs \$t | epoch"; }

# is_running STATE STATES: STATE is one of STATES; jq_in STATES: the same test in jq.
is_running() { case " $2 " in *" $1 "*) true ;; *) false ;; esac; }
jq_in() { printf 'IN(%s)' "$(sed 's/[^ ]*/"&"/g; s/ /, /g' <<<"$1")"; }

# result KIND T0 T1 RTO_S RPO_S CHECK NOTE: one line of restore-drill.tsv, and its reading on the terminal.
result() {
  printing && return 0
  [ -s "$results" ] || printf 'kind\tt0\tt1\trto_s\trpo_s\tcheck\tnote\n' >"$results"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$results"
  printf '%-5s %s: RTO %s s, RPO %s s; %s (in %s)\n' "$6" "$1" "$4" "$5" "$7" "$results"
}

# need_backup_account: vault svp-<env>-copy is in account svp-backup, whose 12 digits only the terminal holds.
need_backup_account() {
  local id=${SVP_AWS_BACKUP_ACCOUNT_ID:-}
  if printing; then
    [ -n "$id" ] || id='<SVP_AWS_BACKUP_ACCOUNT_ID>'
  else
    [[ $id =~ ^[0-9]{12}$ ]] ||
      fail "set SVP_AWS_BACKUP_ACCOUNT_ID to the 12 digits of the svp-backup account, output backup_account_id of aws/org (export SVP_AWS_BACKUP_ACCOUNT_ID=...; never in a committed file): vault $vault-copy is in that account"
  fi
  copy_vault=arn:aws:backup:$region:$id:backup-vault:$vault-copy
}

# read_plan: plan svp-<env>, the one the backup policy makes in the account, into $plan_id and $plan.
read_plan() {
  plan_id=$(q ".BackupPlansList[] | select(.BackupPlanName == \"$vault\") | .BackupPlanId" "<BackupPlanId of plan $vault>" \
    backup list-backup-plans) || fail "list-backup-plans (error above)"
  [ -n "$plan_id" ] ||
    fail "no backup plan $vault in the account of $env_name: policy svp-backup-$env_name of aws/org is not attached to its OU, or AWS has not made the plan yet"
  plan=$(aws_ backup get-backup-plan --backup-plan-id "$plan_id" --output json) || fail "get-backup-plan $plan_id (error above)"
}

# check_plan: the rule, the selection and the opt-in the daily backup relies on are the policy's; the retention of an
# on-demand job and of its copy, $keep_days and $copy_days, are the rule's.
check_plan() {
  local want sel_id sel optin
  read_plan
  if printing; then
    keep_days='<DeleteAfterDays of rule daily>' copy_days='<DeleteAfterDays of its copy action>'
  else
    want=$(jq -nc --arg v "$vault" --arg c "$copy_vault" '{RuleName: "daily", TargetBackupVaultName: $v,
      ScheduleExpression: "cron(0 18 * * ? *)", StartWindowMinutes: 60, CompletionWindowMinutes: 180, CopyTo: [$c]}')
    jq -e --argjson w "$want" '[.BackupPlan.Rules[] | {RuleName, TargetBackupVaultName, ScheduleExpression,
      StartWindowMinutes, CompletionWindowMinutes, CopyTo: [.CopyActions[]?.DestinationBackupVaultArn]}] == [$w]' \
      <<<"$plan" >/dev/null ||
      fail "plan $vault is not the policy's: rules $(jq -c '.BackupPlan.Rules' <<<"$plan"), want one $want"
    keep_days=$(jq -r '.BackupPlan.Rules[0].Lifecycle.DeleteAfterDays' <<<"$plan")
    copy_days=$(jq -r '.BackupPlan.Rules[0].CopyActions[0].Lifecycle.DeleteAfterDays' <<<"$plan")
    [[ $keep_days =~ ^[0-9]+$ && $copy_days =~ ^[0-9]+$ ]] ||
      fail "plan $vault has no retention of days for its recovery points and their copy: $(jq -c '.BackupPlan.Rules' <<<"$plan")"
  fi
  ok "plan $vault: rule daily at cron(0 18 * * ? *) UTC into vault $vault, copied to $copy_vault, kept $keep_days and $copy_days days"
  sel_id=$(q ".BackupSelectionsList[] | select(.SelectionName == \"$vault-tagged\") | .SelectionId" \
    "<SelectionId of $vault-tagged>" backup list-backup-selections --backup-plan-id "$plan_id") || fail "list-backup-selections (error above)"
  [ -n "$sel_id" ] || fail "plan $vault has no selection $vault-tagged: it is not the plan of policy svp-backup-$env_name"
  sel=$(aws_ backup get-backup-selection --backup-plan-id "$plan_id" --selection-id "$sel_id" --output json) ||
    fail "get-backup-selection $sel_id (error above)"
  printing || jq -e --arg r "$role_arn" '.BackupSelection | .IamRoleArn == $r
    and (.Resources | sort) == ["arn:aws:rds:*:*:db:*", "arn:aws:s3:::*"]
    and (.NotResources // []) == [] and (.ListOfTags // []) == []
    and ((.Conditions.StringEquals // []) | map({ConditionKey, ConditionValue}))
      == [{ConditionKey: "aws:ResourceTag/Backup", ConditionValue: "daily"}]
    and ([.Conditions.StringNotEquals, .Conditions.StringLike, .Conditions.StringNotLike] | map(. // []) | add) == []' \
    <<<"$sel" >/dev/null ||
    fail "selection $vault-tagged is not the policy's (role $role_arn, every DB instance and bucket tagged Backup=daily): $(jq -c '.BackupSelection' <<<"$sel")"
  ok "selection $vault-tagged: role $role_arn, every DB instance and bucket tagged Backup=daily"
  optin=$(q '.ResourceTypeOptInPreference | "\(.RDS) \(.S3)"' 'true true' backup describe-region-settings) ||
    fail "describe-region-settings (error above)"
  [ "$optin" = 'true true' ] ||
    fail "opt-in of the account of $env_name in $region: RDS and S3 are '$optin', not 'true true' (aws/accounts/$env_name turns both on)"
  ok "opt-in of RDS and S3 on in $region"
}

# backup_jobs_ended: reads the state of each job of $bjobs ("resource job state recovery_point creation_date") that
# has not ended; true once none is left.
backup_jobs_ended() {
  local arn id state rp created out new='' left=0
  while IFS=$tab read -r arn id state rp created; do
    [ -n "$arn" ] || continue
    if is_running "$state" "$backup_running"; then
      out=$(q '"\(.State)\t\(.RecoveryPointArn // "-")\t\(.CreationDate | epoch | todate)"' \
        "COMPLETED$tab<RecoveryPointArn of job $id>$tab<CreationDate of job $id>" backup describe-backup-job --backup-job-id "$id") ||
        return 1
      IFS=$tab read -r state rp created <<<"$out"
    fi
    if is_running "$state" "$backup_running"; then left=$((left + 1)); fi
    new="$new$arn$tab$id$tab$state$tab$rp$tab$created"$'\n'
  done <<<"$bjobs"
  bjobs=$new
  [ "$left" -eq 0 ]
}

# copy_jobs_ended: the same for $cjobs ("resource job recovery_point creation_date copy_job copy_state").
copy_jobs_ended() {
  local arn id rp created cid state new='' left=0
  while IFS=$tab read -r arn id rp created cid state; do
    [ -n "$arn" ] || continue
    if is_running "$state" "$copy_running"; then
      state=$(q '.CopyJob.State' COMPLETED backup describe-copy-job --copy-job-id "$cid") || return 1
    fi
    if is_running "$state" "$copy_running"; then left=$((left + 1)); fi
    new="$new$arn$tab$id$tab$rp$tab$created$tab$cid$tab$state"$'\n'
  done <<<"$cjobs"
  cjobs=$new
  [ "$left" -eq 0 ]
}

do_backup() {
  local arn id state rp created cid t0 t1 bad=0
  step "restore-drill.sh: on-demand backups of $env_name into vault $vault, copied to account svp-backup"
  check_account
  mark backup-undrained
  need_backup_account
  check_plan
  t0=$(date +%s)
  bjobs=
  for arn in "$db_arn" "arn:aws:s3:::$uploads" "arn:aws:s3:::$media"; do
    id=$(q '.BackupJobId' "<BackupJobId of $arn>" backup start-backup-job --backup-vault-name "$vault" --resource-arn "$arn" \
      --iam-role-arn "$role_arn" --lifecycle "DeleteAfterDays=$keep_days") || fail "start-backup-job of $arn (error above)"
    bjobs="$bjobs$arn$tab$id${tab}CREATED$tab-$tab-"$'\n'
  done
  if ! wait_until "every backup job has ended" "$job_limit" backup_jobs_ended; then
    printf '%s' "$bjobs" | awk -F '\t' '{ printf "        %s %s %s\n", $2, $3, $1 }'
    fail "backup jobs still running after $job_limit s: read each with AWS_PROFILE=$profile aws backup describe-backup-job --backup-job-id <id> --region $region; once they end, run $(basename "$0") $env_name backup again"
  fi
  cjobs=
  while IFS=$tab read -r arn id state rp created; do
    [ -n "$arn" ] || continue
    if [ "$state" != COMPLETED ]; then
      printf 'FAIL  backup job %s of %s ended %s: no recovery point\n' "$id" "$arn" "$state"
      bad=1
      continue
    fi
    ok "backup job $id of $arn completed: $rp"
    cid=$(q '.CopyJobId' "<CopyJobId of $rp>" backup start-copy-job --recovery-point-arn "$rp" --source-backup-vault-name "$vault" \
      --destination-backup-vault-arn "$copy_vault" --iam-role-arn "$role_arn" --lifecycle "DeleteAfterDays=$copy_days") ||
      fail "start-copy-job of $rp (error above)"
    cjobs="$cjobs$arn$tab$id$tab$rp$tab$created$tab$cid${tab}CREATED"$'\n'
  done <<<"$bjobs"
  wait_until "every copy job has ended" "$job_limit" copy_jobs_ended || bad=1
  if ! printing; then
    (umask 077 && printf '%s' "$cjobs" | grep . >"$points.new" || true) && mv "$points.new" "$points"
  fi
  while IFS=$tab read -r arn id rp created cid state; do
    [ -n "$arn" ] || continue
    if [ "$state" = COMPLETED ]; then
      ok "copy job $cid of $rp completed"
    else
      printf 'FAIL  copy job %s of %s is %s: read it with AWS_PROFILE=%s aws backup describe-copy-job --copy-job-id %s --region %s\n' \
        "$cid" "$rp" "$state" "$profile" "$cid" "$region"
      bad=1
    fi
  done <<<"$cjobs"
  printing && return 0
  t1=$(date +%s)
  if [ "$bad" -eq 0 ]; then
    result backup "$(utc "$t0")" "$(utc "$t1")" - - PASS "3 recovery points in $vault, each copied to $vault-copy"
  else
    result backup "$(utc "$t0")" "$(utc "$t1")" - - FAIL "a backup or copy job did not complete (above)"
    fail "the recovery points that completed are in $points; run $(basename "$0") $env_name backup again once the failure is understood"
  fi
}

# pg SERVICE HOST SQL: SQL through svp-pg in pod svp-ops, read-only as the app role of SERVICE; HOST empty is the
# platform's Postgres, the source instance.
pg() {
  kc -n svp-data exec deploy/svp-ops -c postgres -- /opt/svp/bin/svp-pg "$1" ${2:+--host "$2"} -c "$3" </dev/null
}

# check_data HOST FILE: one line "<service> <table> <count> <digest>" per table into FILE. The digest covers every
# column and the xmin of every row, so a write changes it, a value changed and changed back included (new xmin); a
# point-in-time restore replays the WAL, which keeps xmin.
check_data() {
  local host=$1 file=$2 service table out
  printing || : >"$file"
  while read -r service table; do
    out=$(pg "$service" "$host" "SELECT count(*), md5(coalesce(string_agg(r, '|' ORDER BY r), '')) FROM (SELECT t.xmin::text || ':' || t::text AS r FROM $table t) s") ||
      return 1
    printing && continue
    [[ $out =~ ^[0-9]+$'\t'[0-9a-f]{32}$ ]] || {
      printf 'FAIL  svp-pg %s answered %s for table %s, not a count and a digest\n' "$service" "$out" "$table" >&2
      return 1
    }
    printf '%s %s %s\n' "$service" "$table" "${out/$tab/ }" >>"$file"
  done <<<"$tables"
}

# pitr_status: state ("gone" when there is none) and host of svp-<env>-pitr, into $pitr_state and $pitr_host.
pitr_status() {
  local out
  out=$(q '(.DBInstances[0] // {}) | "\(.DBInstanceStatus // "gone")\t\(.Endpoint.Address // "")"' \
    "available$tab<Endpoint.Address of $pitr>" rds describe-db-instances --filters "Name=db-instance-id,Values=$pitr") || return 1
  IFS=$tab read -r pitr_state pitr_host <<<"$out"
}
pitr_available() { pitr_status && [ "$pitr_state" = available ]; }
pitr_gone() { pitr_status && [ "$pitr_state" = gone ]; }

# drop_pitr: deletes svp-<env>-pitr and waits until it is gone, whatever the drill found; also on the way out of a
# failure (trap), with the command to run by hand when that does not work.
drop_pitr() {
  local by_hand="AWS_PROFILE=$profile aws rds delete-db-instance --db-instance-identifier $pitr --skip-final-snapshot --delete-automated-backups --region $region"
  trap - EXIT
  if ! pitr_status; then
    printf 'FAIL  could not read %s: make sure it is deleted: %s\n' "$pitr" "$by_hand" >&2
    return 1
  fi
  if ! printing && [ "$pitr_state" = gone ]; then
    ok "no $pitr left"
    return 0
  fi
  if printing || [ "$pitr_state" != deleting ]; then
    aws_ rds delete-db-instance --db-instance-identifier "$pitr" --skip-final-snapshot --delete-automated-backups \
      --output json >/dev/null || {
      printf 'FAIL  delete-db-instance %s (error above): %s\n' "$pitr" "$by_hand" >&2
      return 1
    }
  fi
  if ! wait_until "$pitr is gone" "$pitr_delete_limit" pitr_gone; then
    printf 'FAIL  %s is still %s after %s s: check it goes, or %s\n' "$pitr" "$pitr_state" "$pitr_delete_limit" "$by_hand" >&2
    return 1
  fi
  ok "$pitr deleted"
}

# lrt_now: LatestRestorableTime of svp-<env>, in epoch seconds, into $lrt.
lrt_now() {
  lrt=$(q '.DBInstances[0].LatestRestorableTime | epoch' 0 rds describe-db-instances --db-instance-identifier "$db")
}
lrt_reached() { lrt_now && [ "$lrt" -ge "$tr" ]; }

do_rds() {
  local s1=$session/restore-drill-s1.txt s2=$session/restore-drill-s2.txt r=$session/restore-drill-r.txt
  local left src subnet_group param_group class sgs t1 tr_utc t0 t2 rto rpo check note
  step "restore-drill.sh: point-in-time restore of $db to $pitr"
  check_account
  mark backup-undrained
  kubeconfig || fail "kubeconfig context $context of cluster $cluster (error above)"
  need_tunnel
  left=$(q '.DBInstances[] | "\(.DBInstanceIdentifier) \(.DBInstanceStatus)"' '' rds describe-db-instances \
    --filters "Name=db-instance-id,Values=$pitr") || fail "describe-db-instances (error above)"
  [ -z "$left" ] ||
    fail "$left is left from an earlier drill, nothing restored over it: AWS_PROFILE=$profile aws rds delete-db-instance --db-instance-identifier $pitr --skip-final-snapshot --delete-automated-backups --region $region; once it is gone, run this again"
  src=$(q '.DBInstances[0] | [.DBSubnetGroup.DBSubnetGroupName, .DBParameterGroups[0].DBParameterGroupName, .DBInstanceClass,
    ([.VpcSecurityGroups[].VpcSecurityGroupId] | join(" "))] | join("\t")' \
    "<DBSubnetGroupName>$tab<DBParameterGroupName>$tab<DBInstanceClass>$tab<VpcSecurityGroupIds>" \
    rds describe-db-instances --db-instance-identifier "$db") || fail "describe-db-instances $db (error above)"
  IFS=$tab read -r subnet_group param_group class sgs <<<"$src"

  check_data "" "$s1" || fail "sample S1 of $db through svp-pg (error above)"
  t1=$(date +%s)
  tr=$((t1 + 1))
  if printing; then tr_utc='<T_r: the end of S1, rounded up to the next second>'; else tr_utc=$(utc "$tr"); fi
  ok "sample S1 of $db; T_r $tr_utc"
  wait_until "LatestRestorableTime of $db is T_r or later" "$lrt_limit" lrt_reached ||
    fail "LatestRestorableTime of $db is still before T_r $tr_utc after $lrt_limit s, nothing restored: read it with AWS_PROFILE=$profile aws rds describe-db-instances --db-instance-identifier $db --query 'DBInstances[0].LatestRestorableTime' --region $region, then run this again"
  check_data "" "$s2" || fail "sample S2 of $db through svp-pg (error above)"
  if ! printing && ! cmp -s "$s1" "$s2"; then
    diff "$s1" "$s2" || true
    result rds - - - - FAIL "source changed during window: S1 and S2 differ (above), nothing restored"
    fail "source changed during window: the drill runs when nothing writes (after the measurements); run it again"
  fi
  ok "sample S2 equals S1"

  lrt_now || fail "describe-db-instances $db (error above)"
  t0=$(date +%s)
  trap drop_pitr EXIT
  # shellcheck disable=SC2086 # one word per security group
  aws_ rds restore-db-instance-to-point-in-time --source-db-instance-identifier "$db" --target-db-instance-identifier "$pitr" \
    --restore-time "$tr_utc" --db-subnet-group-name "$subnet_group" --vpc-security-group-ids $sgs \
    --db-parameter-group-name "$param_group" --db-instance-class "$class" --no-multi-az --no-publicly-accessible \
    --no-deletion-protection --tags Key=Project,Value=svp "Key=Stack,Value=$env_name" --output json >/dev/null ||
    fail "restore-db-instance-to-point-in-time (error above)"
  wait_until "$pitr is available" "$pitr_limit" pitr_available ||
    fail "$pitr is ${pitr_state:-unreadable} after $pitr_limit s"
  check_data "$pitr_host" "$r" || fail "sample R of $pitr through svp-pg (error above)"
  t2=$(date +%s)
  if ! printing; then
    rto=$((t2 - t0)) rpo=$((t0 - lrt))
    check=PASS note="R equals S1 on the tables checked"
    if ! cmp -s "$s1" "$r"; then
      diff "$s1" "$r" || true
      check=FAIL note="restore differs from sample S1 (above): not proof of a wrong restore, a write between S1 and T_r leaves no trace in S1 or S2; read the application logs around T_r"
    fi
    [ "$rto" -le "$rds_rto_target" ] || { check=FAIL note="$note; RTO over $rds_rto_target s"; }
    [ "$rpo" -le "$rds_rpo_target" ] || { check=FAIL note="$note; RPO over $rds_rpo_target s"; }
    result rds "$(utc "$t0")" "$(utc "$t2")" "$rto" "$rpo" "$check" "$note"
  fi
  drop_pitr || exit 1
  printing || [ "$check" = PASS ] || exit 1
}

restore_ended() {
  restore_state=$(q '.Status' COMPLETED backup describe-restore-job --restore-job-id "$job") || return 1
  ! is_running "$restore_state" "$restore_running"
}

sha() { shasum -a 256 "$1" | awk '{ print $1 }'; }

do_s3() {
  local line rp created created_e key dir len_before sha_before len_after sha_after meta marker undo t0 t1 rto rpo check note
  step "restore-drill.sh: one object of $media deleted and restored from the session's recovery point"
  check_account
  mark backup-undrained
  if printing; then
    rp="<recovery_point_arn of the line of arn:aws:s3:::$media in $points>" created='<its creation_date>' created_e=0
  else
    line=$(awk -F '\t' -v a="arn:aws:s3:::$media" '$1 == a' "$points" 2>/dev/null || true)
    [ -n "$line" ] ||
      fail "no line of arn:aws:s3:::$media in $points: run $(basename "$0") $env_name backup first, then this again"
    IFS=$tab read -r _ _ rp created _ <<<"$line"
    created_e=$(to_epoch "$created")
  fi
  key=$(q "[.Contents[]? | select((.Key | endswith(\".m3u8\")) and (.LastModified | epoch) < $created_e) | .Key] | sort | .[0] // empty" \
    '<the first .m3u8 key under media/ older than the recovery point>' s3api list-objects-v2 --bucket "$media" --prefix media/) ||
    fail "list-objects-v2 of $media (error above)"
  [ -n "$key" ] || fail "no .m3u8 under media/ of $media older than its recovery point ($created): nothing to drill on"
  dir=$session/restore-drill-s3
  printing || (umask 077 && mkdir -p "$dir") || fail "create $dir"
  len_before=$(q '.ContentLength' '<ContentLength>' s3api get-object --bucket "$media" --key "$key" "$dir/before") ||
    fail "get-object s3://$media/$key (error above)"
  printing || sha_before=$(sha "$dir/before")
  ok "s3://$media/$key: $len_before bytes, SHA-256 ${sha_before:-<sha>}; deleting it"
  t0=$(date +%s)
  marker=$(q '.VersionId' '<VersionId of the delete marker>' s3api delete-object --bucket "$media" --key "$key") ||
    fail "delete-object s3://$media/$key (error above)"
  # Removing the delete marker brings the object back when the restore does not.
  undo="AWS_PROFILE=$profile aws s3api delete-object --bucket $media --key $key --version-id $marker --region $region"
  meta=$(jq -nc --arg b "$media" --arg k "s3://$media/$key" \
    '{DestinationBucketName: $b, ItemsToRestore: ([$k] | tojson), EncryptionType: "original", RestoreACLs: "false"}')
  job=$(q '.RestoreJobId' '<RestoreJobId>' backup start-restore-job --recovery-point-arn "$rp" --iam-role-arn "$role_arn" \
    --resource-type S3 --metadata "$meta") || fail "start-restore-job of $rp (error above); s3://$media/$key stays deleted, bring it back with: $undo"
  wait_until "restore job $job has ended" "$restore_limit" restore_ended ||
    fail "restore job $job is ${restore_state:-unreadable} after $restore_limit s: read it with AWS_PROFILE=$profile aws backup describe-restore-job --restore-job-id $job --region $region; s3://$media/$key stays deleted until it completes; to bring it back now: $undo"
  if ! printing && [ "$restore_state" != COMPLETED ]; then
    result s3 "$(utc "$t0")" - - - FAIL "restore job $job ended $restore_state; s3://$media/$key stays deleted; bring it back with: $undo"
    fail "restore job $job ended $restore_state; bring s3://$media/$key back with: $undo"
  fi
  len_after=$(q '.ContentLength' '<ContentLength>' s3api get-object --bucket "$media" --key "$key" "$dir/after") ||
    fail "get-object s3://$media/$key after the restore (error above)"
  t1=$(date +%s)
  printing && return 0
  sha_after=$(sha "$dir/after")
  rto=$((t1 - t0)) rpo=$((t0 - created_e))
  # AWS Backup does not keep the ETag: the content is compared, not the ETag.
  check=PASS note="s3://$media/$key restored: $len_after bytes, same SHA-256"
  if [ "$len_after" != "$len_before" ] || [ "$sha_after" != "$sha_before" ]; then
    check=FAIL note="s3://$media/$key restored with other content: $len_after bytes, SHA-256 $sha_after, was $len_before, $sha_before"
  fi
  [ "$rto" -le "$s3_rto_target" ] || { check=FAIL note="$note; RTO over $s3_rto_target s"; }
  result s3 "$(utc "$t0")" "$(utc "$t1")" "$rto" "$rpo" "$check" "$note"
  [ "$check" = PASS ] || exit 1
}

# running_jobs: the backup, copy and restore jobs of the account that have not ended, one "kind id state resource"
# line each, into $running; true when there is none.
running_jobs() {
  local b c r
  b=$(q ".BackupJobs[] | select(.State | $(jq_in "$backup_running")) | \"backup \(.BackupJobId) \(.State) \(.ResourceArn)\"" '' \
    backup list-backup-jobs) || return 1
  c=$(q ".CopyJobs[] | select(.State | $(jq_in "$copy_running")) | \"copy \(.CopyJobId) \(.State) \(.ResourceArn)\"" '' \
    backup list-copy-jobs) || return 1
  r=$(q ".RestoreJobs[] | select(.Status | $(jq_in "$restore_running")) | \"restore \(.RestoreJobId) \(.Status) \(.CreatedResourceArn // \"-\")\"" '' \
    backup list-restore-jobs) || return 1
  running=$(printf '%s\n%s\n%s\n' "$b" "$c" "$r" | grep . || true)
  [ -z "$running" ]
}

untag_db() {
  local found
  found=$(q '.DBInstances[].DBInstanceIdentifier' "$db" rds describe-db-instances --filters "Name=db-instance-id,Values=$db") ||
    fail "describe-db-instances (error above)"
  if [ -z "$found" ]; then
    skip "no DB instance $db: no tag Backup to remove"
    return 0
  fi
  aws_ rds remove-tags-from-resource --resource-name "$db_arn" --tag-keys Backup || fail "remove tag Backup from $db (error above)"
  ok "tag Backup removed from $db"
}

# untag_bucket BUCKET: S3 replaces a bucket's tags as a whole: the set read, less Backup, is written back.
untag_bucket() {
  local b=$1 out rest
  if ! out=$(aws_ s3api get-bucket-tagging --bucket "$b" --output json 2>&1); then
    case $out in
      *NoSuchBucket*) skip "no bucket $b: no tag Backup to remove" && return 0 ;;
      *NoSuchTagSet*) skip "bucket $b has no tags" && return 0 ;;
      *) fail "get-bucket-tagging of $b: $out" ;;
    esac
  fi
  if printing; then
    rest='<TagSet of the bucket without Backup>'
  else
    if ! jq -e 'any(.TagSet[]; .Key == "Backup")' <<<"$out" >/dev/null; then
      skip "bucket $b has no tag Backup"
      return 0
    fi
    rest=$(jq -c '{TagSet: [.TagSet[] | select(.Key != "Backup")]}' <<<"$out")
  fi
  aws_ s3api put-bucket-tagging --bucket "$b" --tagging "$rest" || fail "put-bucket-tagging of $b (error above)"
  ok "tag Backup removed from bucket $b"
}

do_cleanup() {
  local rps copied rp res kept=0 copy_days
  step "restore-drill.sh: backups of $env_name drained before the destroy of root env"
  check_account
  need_backup_account
  drop_pitr || exit 1
  untag_db
  untag_bucket "$uploads"
  untag_bucket "$media"
  if ! wait_until "no backup, copy or restore job of the account is running" "$job_limit" running_jobs; then
    printf '%s\n' "$running" | sed 's/^/        /'
    fail "jobs still running after $job_limit s, nothing deleted: a backup job can be stopped (AWS_PROFILE=$profile aws backup stop-backup-job --backup-job-id <id> --region $region), a copy or restore job only waited for; then run this again"
  fi
  ok "no backup, copy or restore job running"
  rps=$(q '.RecoveryPoints[] | select(.Status != "DELETING") | "\(.RecoveryPointArn) \(.ResourceArn)"' \
    "<each-recovery-point-of-$vault> <its-resource>" backup list-recovery-points-by-backup-vault --backup-vault-name "$vault") ||
    fail "list-recovery-points-by-backup-vault $vault (error above)"
  copied=$(q ".CopyJobs[] | select(.State == \"COMPLETED\" and .DestinationBackupVaultArn == \"$copy_vault\") | .SourceRecoveryPointArn" '' \
    backup list-copy-jobs) || fail "list-copy-jobs (error above)"
  while read -r rp res; do
    [ -n "$rp" ] || continue
    if printing || grep -qxF "$rp" <<<"$copied"; then
      aws_ backup delete-recovery-point --backup-vault-name "$vault" --recovery-point-arn "$rp" ||
        fail "delete-recovery-point $rp (error above)"
      ok "recovery point $rp of $res deleted: its copy is in $vault-copy"
      continue
    fi
    if [ -z "${copy_days:-}" ]; then
      read_plan
      copy_days=$(jq -r '.BackupPlan.Rules[0].CopyActions[0].Lifecycle.DeleteAfterDays' <<<"$plan")
    fi
    printf 'FAIL  recovery point %s of %s has no completed copy in %s, kept\n' "$rp" "$res" "$vault-copy"
    printf '        copy: AWS_PROFILE=%s aws backup start-copy-job --recovery-point-arn %s --source-backup-vault-name %s --destination-backup-vault-arn %s --iam-role-arn %s --lifecycle DeleteAfterDays=%s --region %s\n' \
      "$profile" "$rp" "$vault" "$copy_vault" "$role_arn" "$copy_days" "$region"
    printf '        or accept its loss: AWS_PROFILE=%s aws backup delete-recovery-point --backup-vault-name %s --recovery-point-arn %s --region %s\n' \
      "$profile" "$vault" "$rp" "$region"
    kept=$((kept + 1))
  done <<<"$rps"
  [ "$kept" -eq 0 ] ||
    fail "$kept recovery point(s) of $vault kept, backup-drained not recorded: copy each again or delete it (commands above), then run $(basename "$0") $env_name cleanup again"
  mark backup-drained
  ok "backups of $env_name drained: next, aws/scripts/tf.sh $env_name env plan --destroy"
}

case $cmd in
  backup) do_backup ;;
  rds) do_rds ;;
  s3) do_s3 ;;
  cleanup) do_cleanup ;;
esac
