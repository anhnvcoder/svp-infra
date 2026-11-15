#!/usr/bin/env bash
# Self-test of grafana-tokens.sh against the fake aws and terraform: list prints each token's id and expiry, revoke
# deletes each of them with the account checked right before each delete and lists again; no token means no delete,
# no workspace of an environment with managed_grafana session is a skip; --print reaches nothing.

# Usage: aws/scripts/grafana-tokens-test.sh
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
cp "$src/lib.sh" "$src/grafana-tokens.sh" "$here/"
export SVP_AWS_STG_ACCOUNT_ID=111111111111 SVP_AWS_PRD_ACCOUNT_ID=222222222222
out=$work/out
paid=$work/infra/aws/paid-features.json
printf '{"stg": {"managed_grafana": "session"}}\n' >"$paid"
gt() { bash "$here/grafana-tokens.sh" "$@" >"$out" 2>&1; }
# calls: the fake calls of the last run in order, aws as <service>_<command>, terraform as its last word.
calls() { awk '$1 == "aws" { print "aws_" $2 "_" $3; next } { print $1 " " $NF }' "$log" | tr '\n' '|'; }

# terraform: output grafana_url of aws/accounts/<env>, from $answers/grafana_url (null when the file holds null).
fake_cmd terraform 'case "$1" in */aws/accounts/stg | */aws/accounts/prd) ;; *) exit 1 ;; esac
[ "$2 $3 $4" = "output -json grafana_url" ] || exit 1
cat "$FAKE_ANSWERS/grafana_url"'
printf '"https://g-fake0123.grafana-workspace.ap-southeast-1.amazonaws.com"\n' >"$answers/grafana_url"
printf '{"serviceAccounts": [{"id": "9", "name": "other"}, {"id": "7", "name": "svp-grafana-operator"}]}\n' \
  >"$answers/grafana_list-workspace-service-accounts"
two='{"serviceAccountTokens": [{"id": "41", "name": "a", "expiresAt": "2026-11-16T10:00:00Z"}, {"id": "42", "name": "b", "expiresAt": "2026-11-17T10:00:00Z"}]}'
none='{"serviceAccountTokens": []}'
tokens_answer() { printf '%s\n' "$1" >"$answers/grafana_list-workspace-service-account-tokens"; }
# The fake answers the second list with no token once a delete ran: $answers/after-delete holds that answer.
mv "$bin/aws" "$bin/aws-fake"
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" delete-workspace-service-account-token "*)
    [ ! -e "$FAKE_ANSWERS/after-delete" ] || cp "$FAKE_ANSWERS/after-delete" "$FAKE_ANSWERS/grafana_list-workspace-service-account-tokens" ;;
esac
exec "$(dirname "$0")/aws-fake" "$@"
EOF
chmod +x "$bin/aws"
: >"$answers/grafana_delete-workspace-service-account-token"

# --- arguments ---------------------------------------------------------------------------------------------------
: >"$log"
for args in '' 'stg' 'mgmt list' 'stg delete' 'stg list extra'; do
  # shellcheck disable=SC2086 # the words of args are the arguments
  expect "arguments '$args' are refused with a FAIL" sh -c '! bash "$@" >"$0" 2>&1 && grep -q "^FAIL  " "$0"' "$out" "$here/grafana-tokens.sh" $args
done
expect "refused arguments call nothing" test ! -s "$log"

# --- list --------------------------------------------------------------------------------------------------------
tokens_answer "$two"
: >"$log"
expect "list stg exits 0" gt stg list
expect "list: account check, grafana_url, service accounts, tokens; nothing deleted" \
  test "$(calls)" = "aws_sts_get-caller-identity|terraform grafana_url|aws_grafana_list-workspace-service-accounts|aws_grafana_list-workspace-service-account-tokens|"
expect "list reads the tokens of service account svp-grafana-operator of workspace g-fake0123, in the home region" \
  grep -q '^aws grafana list-workspace-service-account-tokens --workspace-id g-fake0123 --service-account-id 7 --output json --region ap-southeast-1$' "$log"
expect "list counts the tokens" grep -qx 'ok    svp-grafana-operator of stg: 2 token(s)' "$out"
expect "list prints the id and the expiry of each token" \
  sh -c 'grep -qx "note  token 41 expires 2026-11-16T10:00:00Z" "$1" && grep -qx "note  token 42 expires 2026-11-17T10:00:00Z" "$1"' _ "$out"
tokens_answer "$none"
: >"$log"
expect "list of no token exits 0 and counts 0" sh -c 'bash "$1" stg list >"$2" 2>&1 && grep -qx "ok    svp-grafana-operator of stg: 0 token(s)" "$2"' _ "$here/grafana-tokens.sh" "$out"

# --- revoke ------------------------------------------------------------------------------------------------------
tokens_answer "$two"
printf '%s\n' "$none" >"$answers/after-delete"
: >"$log"
expect "revoke prd exits 0" gt prd revoke
expect "revoke: the account checked right before each delete, then the tokens listed again" \
  test "$(calls)" = "aws_sts_get-caller-identity|terraform grafana_url|aws_grafana_list-workspace-service-accounts|aws_grafana_list-workspace-service-account-tokens|aws_sts_get-caller-identity|aws_grafana_delete-workspace-service-account-token|aws_sts_get-caller-identity|aws_grafana_delete-workspace-service-account-token|aws_grafana_list-workspace-service-account-tokens|"
expect "revoke deletes tokens 41 and 42 under profile anhnv-prd" \
  sh -c 'grep -q "^aws grafana delete-workspace-service-account-token --workspace-id g-fake0123 --service-account-id 7 --token-id 41 " "$1" && grep -q "^aws grafana delete-workspace-service-account-token --workspace-id g-fake0123 --service-account-id 7 --token-id 42 " "$1" && grep -q "of prd, arn:aws:sts::222222222222:" "$2"' _ "$log" "$out"
expect "revoke ends with no token left" grep -qx 'ok    no token of svp-grafana-operator left in prd' "$out"
rm "$answers/after-delete"

tokens_answer "$none"
: >"$log"
expect "revoke of no token exits 0" gt stg revoke
expect "revoke of no token says so" grep -qx 'ok    no token of svp-grafana-operator to revoke' "$out"
expect "revoke of no token deletes nothing" sh -c '! grep -q delete-workspace-service-account-token "$1"' _ "$log"

tokens_answer "$two"
: >"$log"
expect "a token left after the deletes: FAIL naming it" \
  sh -c '! bash "$1" stg revoke >"$2" 2>&1 && grep -q "^FAIL  tokens of svp-grafana-operator left after the deletes: 41 42" "$2"' _ "$here/grafana-tokens.sh" "$out"

# A profile that turns into another account between two deletes stops before the next delete.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" delete-workspace-service-account-token "*) touch "$FAKE_ANSWERS/switched" ;;
  *" get-caller-identity "*)
    if [ -e "$FAKE_ANSWERS/switched" ]; then
      echo "aws $*" >>"$FAKE_LOG"
      echo '{"Account": "999999999999", "Arn": "arn:aws:sts::999999999999:assumed-role/Other/x"}'
      exit 0
    fi ;;
esac
exec "$(dirname "$0")/aws-fake" "$@"
EOF
: >"$log"
expect "the account changes after the first delete: FAIL before the second" \
  sh -c '! bash "$1" stg revoke >"$2" 2>&1 && grep -q "^FAIL  profile anhnv-stg is account .999999999999." "$2" && test "$(grep -c delete-workspace-service-account-token "$3")" = 1' \
  _ "$here/grafana-tokens.sh" "$out" "$log"
rm -f "$answers/switched"
printf '#!/usr/bin/env bash\nexec "$(dirname "$0")/aws-fake" "$@"\n' >"$bin/aws"

# --- no workspace ------------------------------------------------------------------------------------------------
printf 'null\n' >"$answers/grafana_url"
: >"$log"
expect "stg without a workspace (managed_grafana session): exits 0" gt stg revoke
expect "stg without a workspace: skip giving the reason" \
  grep -qx 'skip  no Grafana workspace in stg (managed_grafana session in aws/paid-features.json, no session open), so no token of svp-grafana-operator' "$out"
expect "stg without a workspace: no Grafana call" sh -c '! grep -q "^aws grafana" "$1"' _ "$log"
: >"$log"
expect "prd without a workspace (managed_grafana always): FAIL naming the apply" \
  sh -c '! bash "$1" prd list >"$2" 2>&1 && grep -q "^FAIL  output grafana_url of aws/accounts/prd is null though managed_grafana of prd is always" "$2"' _ "$here/grafana-tokens.sh" "$out"
printf '"https://g-fake0123.grafana-workspace.ap-southeast-1.amazonaws.com"\n' >"$answers/grafana_url"

# --- what stops it -----------------------------------------------------------------------------------------------
printf '{"serviceAccounts": [{"id": "9", "name": "other"}]}\n' >"$answers/grafana_list-workspace-service-accounts"
: >"$log"
expect "no service account svp-grafana-operator: FAIL, no token read" \
  sh -c '! bash "$1" stg list >"$2" 2>&1 && grep -q "^FAIL  Grafana workspace g-fake0123 has no service account svp-grafana-operator" "$2" && ! grep -q list-workspace-service-account-tokens "$3"' \
  _ "$here/grafana-tokens.sh" "$out" "$log"
printf '{"serviceAccounts": [{"id": "7", "name": "svp-grafana-operator"}]}\n' >"$answers/grafana_list-workspace-service-accounts"
: >"$log"
expect "SVP_AWS_STG_ACCOUNT_ID of another account: FAIL before terraform and Grafana" \
  sh -c '! env SVP_AWS_STG_ACCOUNT_ID=999999999999 bash "$1" stg revoke >"$2" 2>&1 && grep -q "^FAIL  profile anhnv-stg is account" "$2" && ! grep -q -e terraform -e "^aws grafana" "$3"' \
  _ "$here/grafana-tokens.sh" "$out" "$log"

# --- --print -----------------------------------------------------------------------------------------------------
: >"$log"
expect "--print stg revoke exits 0" gt --print stg revoke
expect "--print calls nothing" test ! -s "$log"
expect "--print shows the delete, then the account check before it" \
  sh -c 'grep -q "^+ AWS_PROFILE=anhnv-stg aws grafana delete-workspace-service-account-token --workspace-id .<g-id of output grafana_url>. --service-account-id .<id of service account svp-grafana-operator>. --token-id .<id>. --output json --region ap-southeast-1$" "$1" && test "$(grep -c "aws sts get-caller-identity" "$1")" = 2' _ "$out"
expect "--print shows the output it reads" grep -q '^+ AWS_PROFILE=anhnv-stg terraform -chdir=.*/aws/accounts/stg output -json grafana_url$' "$out"
: >"$log"
expect "--print prd list exits 0 and calls nothing" sh -c 'bash "$1" --print prd list >"$2" 2>&1 && [ ! -s "$3" ]' _ "$here/grafana-tokens.sh" "$out" "$log"

finish
