#!/usr/bin/env bash
# Self-test of sso-profiles.sh: write adds or replaces only the blocks of the profiles of the table, keeps every other
# byte of the config file, comes out the same when run again, and refuses a file without a root profile on an SSO
# session; check signs in with each profile against the fake aws and goes on after a FAIL; --print reaches nothing.

# Usage: aws/scripts/sso-profiles-test.sh
#
# The checks run sh -c '...' with their values as arguments ($1, $2, ...): expanded by that shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=aws/scripts/testlib.sh
. "$src/testlib.sh"
fake_aws
here=$work/infra/aws/scripts
mkdir -p "$here"
cp "$src/lib.sh" "$src/profiles.sh" "$src/sso-profiles.sh" "$here/"
cfg=$AWS_CONFIG_FILE out=$work/out
run() { bash "$here/sso-profiles.sh" "$@" >"$out" 2>&1; }
unset SVP_AWS_MGMT_ACCOUNT_ID SVP_AWS_STG_ACCOUNT_ID SVP_AWS_PRD_ACCOUNT_ID SVP_AWS_LOG_ACCOUNT_ID \
  SVP_AWS_SECURITY_ACCOUNT_ID SVP_AWS_BACKUP_ACCOUNT_ID
export SVP_AWS_MGMT_ACCOUNT_ID=000000000000 SVP_AWS_STG_ACCOUNT_ID=111111111111 SVP_AWS_PRD_ACCOUNT_ID=222222222222 \
  SVP_AWS_LOG_ACCOUNT_ID=333333333333 SVP_AWS_SECURITY_ACCOUNT_ID=444444444444

# blk PROFILE SESSION ACCOUNT ROLE: the block write must make, written out here and not read from the script.
blk() { printf '[profile %s]\nsso_session = %s\nsso_account_id = %s\nsso_role_name = %s\nregion = ap-southeast-1\noutput = json\n' "$@"; }
same() { cmp -s "$1" "$2"; }

# The learner's file: a default section, the root profile on session lab, a block of anhnv-stg written by hand in the
# legacy format, the session, and a profile of another project whose bytes (comment, spacing) must stay.
root='[profile anhnv-sso]
sso_session = lab
sso_account_id = 000000000000
sso_role_name = AdministratorAccess
region = ap-southeast-1
output = json
'
session='[sso-session lab]
sso_start_url = https://d-0000000000.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
'
other='[profile other]
# kept as written
region=eu-west-1
output = text
'
{
  printf '[default]\nregion = us-east-1\n\n%s\n' "$root"
  printf '[profile anhnv-stg]\nsso_start_url = https://d-0000000000.awsapps.com/start\nsso_region = us-east-1\n'
  printf 'sso_account_id = 111111111111\nsso_role_name = AdministratorAccess\n\n%s\n%s' "$session" "$other"
} >"$work/start"
{
  printf '[default]\nregion = us-east-1\n\n%s\n' "$root"
  blk anhnv-stg lab 111111111111 SvpAdmin
  printf '\n%s\n%s\n' "$session" "$other"
  blk anhnv-stg-ro lab 111111111111 SvpReadOnly
  echo
  blk anhnv-prd lab 222222222222 SvpAdmin
  echo
  blk anhnv-prd-ro lab 222222222222 SvpReadOnly
  echo
  blk anhnv-log-ro lab 333333333333 SvpLogReader
  echo
  blk anhnv-security-ro lab 444444444444 SvpReadOnly
} >"$work/want"

# --- write: the root profile must be there, on an SSO session ------------------------------------------------------
expect "write without a config file FAILs, naming aws configure sso, and makes no file" \
  sh -c '! bash "$1" write >"$2" 2>&1 && grep -q "^FAIL  no .*config, so no profile anhnv-sso: make it with aws configure sso --profile anhnv-sso" "$2" && [ ! -e "$3" ]' \
  _ "$here/sso-profiles.sh" "$out" "$cfg"
printf '[default]\nregion = us-east-1\n' >"$cfg"
cp "$cfg" "$work/before"
expect "write without [profile anhnv-sso] FAILs and writes nothing" \
  sh -c '! bash "$1" write >"$2" 2>&1 && grep -q "^FAIL  no \[profile anhnv-sso\] in .*aws configure sso" "$2" && cmp -s "$3" "$4"' \
  _ "$here/sso-profiles.sh" "$out" "$cfg" "$work/before"
printf '[profile anhnv-sso]\nsso_start_url = https://d-0000000000.awsapps.com/start\nsso_region = us-east-1\nsso_account_id = 000000000000\nsso_role_name = AdministratorAccess\n' >"$cfg"
cp "$cfg" "$work/before"
expect "write with anhnv-sso in the legacy format (no sso_session) FAILs and writes nothing" \
  sh -c '! bash "$1" write >"$2" 2>&1 && grep -q "^FAIL  \[profile anhnv-sso\] of .* has no sso_session (the legacy SSO format" "$2" && cmp -s "$3" "$4"' \
  _ "$here/sso-profiles.sh" "$out" "$cfg" "$work/before"
printf '%s' "$root" >"$cfg"
cp "$cfg" "$work/before"
expect "write with an sso_session that has no [sso-session] block FAILs and writes nothing" \
  sh -c '! bash "$1" write >"$2" 2>&1 && grep -q "^FAIL  no \[sso-session lab\] in " "$2" && cmp -s "$3" "$4"' \
  _ "$here/sso-profiles.sh" "$out" "$cfg" "$work/before"

# --- write: the profiles of the table, nothing else ---------------------------------------------------------------
cp "$work/start" "$cfg"
cp "$cfg" "$work/before"
expect "write with an account variable that is not 12 digits FAILs and writes nothing" \
  sh -c '! env SVP_AWS_PRD_ACCOUNT_ID=2222 bash "$1" write >"$2" 2>&1 && grep -q "^FAIL  SVP_AWS_PRD_ACCOUNT_ID is not the 12 digits" "$2" && cmp -s "$3" "$4"' \
  _ "$here/sso-profiles.sh" "$out" "$cfg" "$work/before"

: >"$log"
expect "write --print exits 0" run --print write
expect "write --print shows the block of each of the seven profiles" \
  test "$(grep -c '^  (block \[profile anhnv-' "$out")" = 7
expect "write --print calls no command and leaves the file as it was" sh -c '[ ! -s "$1" ] && cmp -s "$2" "$3"' _ "$log" "$cfg" "$work/before"

expect "write exits 0" run write
expect "write gives the file exactly the expected bytes: the blocks of the table, every other byte kept" same "$cfg" "$work/want"
expect "write notes that the hand-written block of anhnv-stg was replaced" \
  grep -qx 'note  profile anhnv-stg: block replaced by the one of this script (it had other keys or values)' "$out"
expect "write adds the profiles the file lacked" \
  test "$(grep -c '^ok    profile anhnv-.*: added, account of SVP_AWS_' "$out")" = 5
expect "write skips anhnv-backup-ro, whose variable is not exported" \
  sh -c 'grep -q "^skip  profile anhnv-backup-ro: SVP_AWS_BACKUP_ACCOUNT_ID is not exported" "$1" && ! grep -q "anhnv-backup-ro\]" "$2"' _ "$out" "$cfg"
expect "write prints no account id" no_leak 111111111111 "$out"
expect "write leaves no temporary file beside the config" test "$(ls -A "$(dirname "$cfg")")" = config
expect "write calls no aws" sh -c '! grep -q "^aws " "$1"' _ "$log"

cp "$cfg" "$work/before"
expect "write again with the same variables exits 0" run write
expect "write again leaves the file byte for byte" same "$cfg" "$work/before"
expect "write again says unchanged, with no note" sh -c 'grep -q "^ok    .*config unchanged$" "$1" && ! grep -q "^note" "$1"' _ "$out"

expect "write with another account in SVP_AWS_PRD_ACCOUNT_ID exits 0" env SVP_AWS_PRD_ACCOUNT_ID=666666666666 bash "$here/sso-profiles.sh" write >"$out" 2>&1
expect "write notes the two prd profiles by name, without the id" \
  sh -c 'test "$(grep -Ec "^note  profile anhnv-prd(-ro)?: sso_account_id replaced by the account of SVP_AWS_PRD_ACCOUNT_ID$" "$1")" = 2 && ! grep -q 666666666666 "$1"' _ "$out"
expect "write changes only the sso_account_id of the prd profiles" \
  sh -c 'diff "$1" "$2" | grep "^[<>]" | sort | uniq -c | awk "{ print \$1, \$2, \$3, \$4, \$5 }" | tr "\n" "|" | grep -qx "2 < sso_account_id = 222222222222|2 > sso_account_id = 666666666666|"' \
  _ "$work/before" "$cfg"
cp "$work/want" "$cfg"

expect "write with SVP_AWS_BACKUP_ACCOUNT_ID exported exits 0" env SVP_AWS_BACKUP_ACCOUNT_ID=555555555555 bash "$here/sso-profiles.sh" write >"$out" 2>&1
expect "write appends anhnv-backup-ro after a blank line, the rest as before" \
  sh -c '{ cat "$2"; echo; printf "%s\n" "[profile anhnv-backup-ro]" "sso_session = lab" "sso_account_id = 555555555555" "sso_role_name = SvpReadOnly" "region = ap-southeast-1" "output = json"; } | cmp -s - "$1"' \
  _ "$cfg" "$work/want"
cp "$work/want" "$cfg"

expect "write without AWS_CONFIG_FILE writes \$HOME/.aws/config" \
  sh -c 'mv "$1" "$1.aside"; printf "%s\n%s" "$2" "$3" >"$HOME/.aws/config"; env -u AWS_CONFIG_FILE bash "$4" write >/dev/null 2>&1 && grep -q "^\[profile anhnv-prd\]$" "$HOME/.aws/config"; rc=$?; mv "$1.aside" "$1"; exit $rc' \
  _ "$cfg" "$root" "$session" "$here/sso-profiles.sh"
cp "$work/want" "$cfg"

# --- check -------------------------------------------------------------------------------------------------------
: >"$log"
expect "check --print exits 0" run --print check
expect "check --print shows the sts call of each of the eight profiles" \
  test "$(grep -c '^+ AWS_PROFILE=anhnv-[a-z-]* aws sts get-caller-identity --output json --region ap-southeast-1$' "$out")" = 8
expect "check --print calls no aws" test ! -s "$log"

expect "check exits 0 when every profile is its account" run check
expect "check passes the seven profiles in the file whose variable is exported" test "$(grep -c '^ok    account ' "$out")" = 7
expect "check skips anhnv-backup-ro, which is not in the file" grep -q '^skip  profile anhnv-backup-ro: not in ' "$out"
expect "check signs in once with each profile it checks" test "$(grep -c '^aws sts get-caller-identity' "$log")" = 7

expect "check skips a profile whose variable is not exported" \
  sh -c 'env -u SVP_AWS_LOG_ACCOUNT_ID bash "$1" check >"$2" 2>&1 && grep -q "^skip  profile anhnv-log-ro: SVP_AWS_LOG_ACCOUNT_ID is not exported" "$2"' \
  _ "$here/sso-profiles.sh" "$out"

# One profile on another account and one whose SSO session expired: both FAIL, the profiles after them still run.
mv "$bin/aws" "$bin/aws-fake"
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
if [ "${AWS_PROFILE:-}" = anhnv-prd-ro ]; then
  echo "aws $*" >>"$FAKE_LOG"
  echo "Error when retrieving token from sso: Token has expired and refresh failed" >&2
  exit 255
fi
exec "$(dirname "$0")/aws-fake" "$@"
EOF
chmod +x "$bin/aws"
expect "check exits 1 with one profile on another account and one expired session" \
  sh -c '! env SVP_AWS_LOG_ACCOUNT_ID=999999999999 bash "$1" check >"$2" 2>&1' _ "$here/sso-profiles.sh" "$out"
expect "check FAILs anhnv-log-ro, on another account" grep -q '^FAIL  profile anhnv-log-ro is account .333333333333.' "$out"
expect "check FAILs anhnv-prd-ro, whose session expired, naming aws sso login" \
  grep -q '^FAIL  aws sts get-caller-identity with profile anhnv-prd-ro (expired SSO session? AWS_PROFILE=anhnv-prd-ro aws sso login)' "$out"
expect "check goes on after a FAIL: anhnv-security-ro still passes" grep -q '^ok    account 444444444444 of security,' "$out"
expect "check ends with the count of failed profiles" grep -q '^FAIL  2 profile(s) failed' "$out"
mv "$bin/aws-fake" "$bin/aws"

expect "the test never wrote outside its own tree" test "$cfg" = "$work/home/.aws/config"
finish
