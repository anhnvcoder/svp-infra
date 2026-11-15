# shellcheck shell=bash
# The profiles of the lab's accounts, sourced by the session scripts after lib.sh: a script that runs a command under a
# profile that is not the one of its environment (a read-only profile, the account of the logs) takes the profile and
# the account variable of its row here, so that check_account, aws_, aws_global_ and tf_ of lib.sh work on it as on an
# environment. Design notes: README.md.

# shellcheck disable=SC2034 # read by the scripts that source this file
# The profiles, one line each. Fields, read by profile_arg: profile, variable with the 12 digits of the account,
# permission set of the profile (- for the root profile, made by hand), name of the account.
profile_table='anhnv-sso SVP_AWS_MGMT_ACCOUNT_ID - mgmt
anhnv-stg SVP_AWS_STG_ACCOUNT_ID SvpAdmin stg
anhnv-stg-ro SVP_AWS_STG_ACCOUNT_ID SvpReadOnly stg
anhnv-prd SVP_AWS_PRD_ACCOUNT_ID SvpAdmin prd
anhnv-prd-ro SVP_AWS_PRD_ACCOUNT_ID SvpReadOnly prd
anhnv-log-ro SVP_AWS_LOG_ACCOUNT_ID SvpLogReader log
anhnv-security-ro SVP_AWS_SECURITY_ACCOUNT_ID SvpReadOnly security
anhnv-backup-ro SVP_AWS_BACKUP_ACCOUNT_ID SvpReadOnly backup'

# profile_arg PROFILE: sets profile, account_var and env_name from the row of PROFILE, and nothing else of lib.sh.
profile_arg() {
  local line
  line=$(awk -v p="${1:-}" '$1 == p' <<<"$profile_table")
  [ -n "$line" ] || fail "profile '${1:-}' is not one of $(awk '{ print $1 }' <<<"$profile_table" | oneline)"
  # shellcheck disable=SC2034 # read by the scripts that source this file
  read -r profile account_var _ env_name <<<"$line"
}
