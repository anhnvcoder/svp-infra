# shellcheck shell=bash
# Harness shared by the *-test.sh files of this directory, sourced by each of them: . "$src/tests/testlib.sh".
# It makes a temporary tree, puts a directory of fake commands first on PATH and points HOME and AWS_CONFIG_FILE at the
# tree, so a test never reaches an account or reads the learner's ~/.aws. Runs on bash 3.2 (Mac) and on Linux.

# Usage in a test: expect "<name>" <command...> for each check, finish last. After fake_aws, the fake aws answers from
# the file $answers/<words of the command up to the first option, joined by _>, e.g. organizations_list-accounts.
# Variables: work (the tree), bin, answers, log (every fake call, one per line), failures.

# shellcheck disable=SC2034 # read by the tests that source this file

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
work=$(cd "$work" && pwd)
bin=$work/bin answers=$work/answers log=$work/calls.log failures=0
mkdir -p "$bin" "$answers" "$work/home/.aws"
: >"$log"

# Nothing of the learner's session may steer a fake: no profile, region or credential, and an empty home.
unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export HOME=$work/home
export AWS_CONFIG_FILE=$work/home/.aws/config
export AWS_SHARED_CREDENTIALS_FILE=$work/home/.aws/credentials
export FAKE_LOG=$log FAKE_ANSWERS=$answers

# The account each profile of the lab signs in to (the table of profiles of the runbooks), fake ids.
export FAKE_ACCOUNTS='anhnv-sso 000000000000
anhnv-stg 111111111111
anhnv-stg-ro 111111111111
anhnv-prd 222222222222
anhnv-prd-ro 222222222222
anhnv-log-ro 333333333333
anhnv-security-ro 444444444444
anhnv-backup-ro 555555555555'

# A test that does not call fake_aws still finds this guard, never the aws of the machine.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $* (guard: fake_aws not called)" >>"$FAKE_LOG"
echo "aws: the real aws is out of reach of the tests; call fake_aws" >&2
exit 99
EOF
chmod +x "$bin/aws"
PATH=$bin:$PATH
export PATH

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

# finish: the last line of a test; exits 1 when a check failed.
finish() {
  if [ "$failures" -gt 0 ]; then
    echo "FAIL  $failures check(s) failed" >&2
    exit 1
  fi
  echo "ok    every check passed"
}

# fake_aws: the aws of the tests. It logs the call, then exits 97 without AWS_PROFILE in the environment, with a profile
# outside FAKE_ACCOUNTS, or without --region; sts get-caller-identity answers as the account of the profile; any other
# command answers with the file of its key, or exits 96 and logs "no answer: <key>".
fake_aws() {
  cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
[ -n "${AWS_PROFILE:-}" ] || { echo "fake aws: AWS_PROFILE is not set" >&2; exit 97; }
account=$(awk -v p="$AWS_PROFILE" '$1 == p { print $2 }' <<<"$FAKE_ACCOUNTS")
[ -n "$account" ] || { echo "fake aws: profile '$AWS_PROFILE' is not in the table of profiles" >&2; exit 97; }
region= prev=
for a in "$@"; do [ "$prev" != --region ] || region=$a; prev=$a; done
[ -n "$region" ] || { echo "fake aws: no --region in the command" >&2; exit 97; }
key=
for a in "$@"; do
  case $a in -*) break ;; esac
  key=${key:+${key}_}$a
done
if [ "$key" = sts_get-caller-identity ]; then
  printf '{"UserId": "AIDAFAKE", "Account": "%s", "Arn": "arn:aws:sts::%s:assumed-role/Fake/test"}\n' "$account" "$account"
  exit 0
fi
if [ -n "$key" ] && [ -f "$FAKE_ANSWERS/$key" ]; then
  cat "$FAKE_ANSWERS/$key"
  exit 0
fi
echo "no answer: $key" >>"$FAKE_LOG"
echo "fake aws: no answer file for '$key'" >&2
exit 96
EOF
  chmod +x "$bin/aws"
  [ "$(command -v aws)" = "$bin/aws" ] || {
    echo "FAIL  the aws first on PATH is $(command -v aws), not the fake" >&2
    exit 1
  }
}

# fake_cmd NAME SCRIPT: a command NAME (terraform, gh, dig...) that logs its call, then runs SCRIPT, bash code with the
# arguments as $1, $2, ...
fake_cmd() {
  # shellcheck disable=SC2016 # $* is for the generated script
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE_LOG"\n%s\n' "$1" "$2" >"$bin/$1"
  chmod +x "$bin/$1"
}

# no_leak VALUE FILE...: VALUE is in none of the files (a file that does not exist holds nothing). An empty VALUE is a
# mistake of the test, not a pass.
no_leak() {
  local value=$1 f
  shift
  [ -n "$value" ] || return 2
  for f in "$@"; do
    ! grep -qF -- "$value" "$f" 2>/dev/null || return 1
  done
}
