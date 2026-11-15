#!/usr/bin/env bash
# Self-test of cache-secrets.sh against the fake aws: the credential on stdin reaches put-secret-value of the right
# entry as JSON through stdin, the account checked first; the token never shows up in the output, in the log of the
# fake or in a file of the temporary tree, a failing write included; a bad or missing token or key writes nothing;
# --print reaches nothing and reads nothing.

# Usage: aws/scripts/cache-secrets-test.sh
#
# The checks run sh -c '...' with their values as arguments ($1, $2, ...): expanded by that shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=aws/scripts/testlib.sh
. "$src/testlib.sh"
fake_aws
here=$work/infra/aws/scripts
mkdir -p "$here" "$work/tmp"
cp "$src/lib.sh" "$src/cache-secrets.sh" "$here/"
export SVP_AWS_STG_ACCOUNT_ID=111111111111 SVP_AWS_PRD_ACCOUNT_ID=222222222222 TMPDIR=$work/tmp
out=$work/out

# In front of the fake aws: put-secret-value logs whether its stdin is $FAKE_WANT, or, once $answers/put-fails
# exists, fails with an error that repeats its stdin, as a careless CLI might.
mv "$bin/aws" "$bin/aws-fake"
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" put-secret-value "*)
    got=$(cat)
    if [ -e "$FAKE_ANSWERS/put-fails" ]; then
      echo "aws $*" >>"$FAKE_LOG"
      echo "An error occurred (AccessDeniedException) when calling PutSecretValue: denied for $got" >&2
      exit 254
    fi
    if [ "$got" = "${FAKE_WANT:-}" ]; then echo "stdin is the credential" >>"$FAKE_LOG"; else echo "stdin differs" >>"$FAKE_LOG"; fi
    ;;
esac
exec "$(dirname "$0")/aws-fake" "$@"
EOF
chmod +x "$bin/aws"
printf 'ecr-pullthroughcache/ghcr\n' >"$answers/secretsmanager_describe-secret"
printf '0123456789abcdef-fake-version\n' >"$answers/secretsmanager_put-secret-value"

ghp=ghp_FakeToken0123456789abcdefghijklmnopq
dckr=dckr_pat_Fake-Token_0123456789
# cs ENV UPSTREAM STDIN: cache-secrets.sh ENV UPSTREAM with STDIN on its stdin (not a terminal), output in $out.
cs() { printf '%s' "$3" | bash "$here/cache-secrets.sh" "$1" "$2" >"$out" 2>&1; }
# calls: the aws calls of the last run in order, as <service>_<command>.
calls() { awk '$1 == "aws" { print $2 "_" $3 }' "$log" | tr '\n' '|'; }
# nowhere VALUE: VALUE is in no file of the temporary tree: output, log of the fake, TMPDIR.
nowhere() {
  local files
  files=$(find "$work" -type f ! -path "$bin/*")
  # shellcheck disable=SC2086 # one path per word; mktemp paths have no space
  no_leak "$1" $files
}
tmp_empty() { [ -z "$(ls -A "$work/tmp")" ]; }

# --- arguments ---------------------------------------------------------------------------------------------------
: >"$log"
for args in '' 'stg' 'mgmt ghcr' 'stg quay' 'stg ghcr extra'; do
  # shellcheck disable=SC2086 # the words of args are the arguments
  expect "arguments '$args' are refused with a FAIL" sh -c '! bash "$@" </dev/null >"$0" 2>&1 && grep -q "^FAIL  " "$0"' "$out" "$here/cache-secrets.sh" $args
done
expect "refused arguments call nothing" test ! -s "$log"

# --- a write -----------------------------------------------------------------------------------------------------
: >"$log"
export FAKE_WANT="{\"username\":\"learner\",\"accessToken\":\"$ghp\"}"
expect "ghcr of stg from stdin exits 0" cs stg ghcr "{\"username\": \"learner\", \"accessToken\": \"$ghp\"}"
expect "ghcr: account check, the entry read, then the write" \
  test "$(calls)" = "sts_get-caller-identity|secretsmanager_describe-secret|secretsmanager_put-secret-value|"
expect "the write goes to entry ecr-pullthroughcache/ghcr, value from stdin, profile and region in the command" \
  grep -q '^aws secretsmanager put-secret-value --secret-id ecr-pullthroughcache/ghcr --secret-string file:///dev/stdin --query VersionId --output text --region ap-southeast-1$' "$log"
expect "put-secret-value reads exactly {username, accessToken} on its stdin" grep -qx 'stdin is the credential' "$log"
expect "the run prints the first 8 characters of VersionId" \
  grep -qx 'ok    entry ecr-pullthroughcache/ghcr of stg: version 01234567 (value not shown); next: the validate loop of docs/runbooks/platform-setup.md, step (5)' "$out"
expect "the token is in no output, log or file of the tree" nowhere "$ghp"
expect "no temporary file is left in TMPDIR" tmp_empty

: >"$log"
export FAKE_WANT="{\"username\":\"learner\",\"accessToken\":\"$dckr\"}"
expect "dockerhub of prd from stdin exits 0" cs prd dockerhub "{\"accessToken\":\"$dckr\",\"username\":\"learner\"}"
expect "dockerhub: entry ecr-pullthroughcache/docker-hub under profile anhnv-prd" \
  sh -c 'grep -q "^aws secretsmanager put-secret-value --secret-id ecr-pullthroughcache/docker-hub " "$1" && grep -qx "stdin is the credential" "$1" && grep -q "of prd, arn:aws:sts::222222222222:" "$2"' _ "$log" "$out"
expect "the Docker Hub token is in no output, log or file of the tree" nowhere "$dckr"

: >"$log"
export FAKE_WANT="{\"username\":\"learner\",\"accessToken\":\"$ghp\"}"
expect "a second run writes again (a new version, safe)" cs stg ghcr "{\"username\":\"learner\",\"accessToken\":\"$ghp\"}"
expect "a second run writes once more" test "$(grep -c '^aws secretsmanager put-secret-value ' "$log")" = 1

# --- refused before the write ------------------------------------------------------------------------------------
# refused NAME UPSTREAM STDIN GREP: the run fails with a FAIL matching GREP and never calls put-secret-value.
refused() {
  : >"$log"
  expect "$1: FAIL" sh -c '! printf "%s" "$2" | bash "$1" stg "$4" >"$3" 2>&1 && grep -q "^FAIL  $5" "$3"' _ \
    "$here/cache-secrets.sh" "$3" "$out" "$2" "$4"
  expect "$1: nothing written" sh -c '! grep -q put-secret-value "$1"' _ "$log"
}
refused "a GitHub token given for Docker Hub" dockerhub "{\"username\":\"learner\",\"accessToken\":\"$ghp\"}" \
  'the token is not of the form dckr_pat_'
expect "a refused token is not printed" nowhere "$ghp"
refused "an empty token" ghcr '{"username":"learner","accessToken":""}' 'stdin is not {"username"'
refused "a token with a quote" ghcr '{"username":"learner","accessToken":"ghp_a\"b"}' 'the token is not of the form ghp_'
refused "no accessToken key" ghcr '{"username":"learner"}' 'stdin is not {"username"'
refused "no username key" ghcr "{\"accessToken\":\"$ghp\"}" 'stdin is not {"username"'
refused "a number as accessToken" ghcr '{"username":"learner","accessToken":12}' 'stdin is not {"username"'
refused "stdin not JSON" ghcr "$ghp" 'stdin is not {"username"'
expect "stdin that is not JSON is not printed" nowhere "$ghp"
refused "empty stdin" ghcr '' 'stdin is not {"username"'
refused "the token typed as the user name" ghcr "{\"username\":\"$ghp x\",\"accessToken\":\"$ghp\"}" \
  'the GitHub user is not letters'
expect "a bad user name is not printed" nowhere "$ghp"

: >"$log"
mv "$answers/secretsmanager_describe-secret" "$work/describe"
expect "no entry (aws/accounts not applied): FAIL naming step (5), nothing written" \
  sh -c '! printf "%s" "$2" | bash "$1" stg ghcr >"$3" 2>&1 && grep -q "^FAIL  no entry ecr-pullthroughcache/ghcr in stg: apply aws/accounts/stg first" "$3" && ! grep -q put-secret-value "$4"' \
  _ "$here/cache-secrets.sh" "{\"username\":\"learner\",\"accessToken\":\"$ghp\"}" "$out" "$log"
mv "$work/describe" "$answers/secretsmanager_describe-secret"

: >"$log"
expect "SVP_AWS_STG_ACCOUNT_ID of another account: FAIL before the entry is read" \
  sh -c '! printf "%s" "$2" | env SVP_AWS_STG_ACCOUNT_ID=999999999999 bash "$1" stg ghcr >"$3" 2>&1 && grep -q "^FAIL  profile anhnv-stg is account" "$3" && ! grep -q secretsmanager "$4"' \
  _ "$here/cache-secrets.sh" "{\"username\":\"learner\",\"accessToken\":\"$ghp\"}" "$out" "$log"

# --- a write that fails ------------------------------------------------------------------------------------------
: >"$log"
touch "$answers/put-fails"
expect "put-secret-value fails: FAIL that says to run it again" \
  sh -c '! printf "%s" "$2" | bash "$1" stg ghcr >"$3" 2>&1 && grep -q "^FAIL  write entry ecr-pullthroughcache/ghcr of stg (nothing else changed; run cache-secrets.sh again): An error occurred (AccessDeniedException)" "$3"' \
  _ "$here/cache-secrets.sh" "{\"username\":\"learner\",\"accessToken\":\"$ghp\"}" "$out"
expect "put-secret-value fails: the error of aws shows <token> instead of the token" grep -qF '"accessToken":"<token>"' "$out"
expect "put-secret-value fails: the token is in no output, log or file of the tree" nowhere "$ghp"
expect "put-secret-value fails: no ok line of a version" sh -c '! grep -q "^ok    entry .* version" "$1"' _ "$out"
rm "$answers/put-fails"

# --- the token's variables ---------------------------------------------------------------------------------------
expect "the variables holding the token are unset on every exit (trap EXIT)" \
  grep -qx "trap 'unset user token input json' EXIT" "$here/cache-secrets.sh"

# --- typed on a terminal -----------------------------------------------------------------------------------------
# on_tty TRANSCRIPT STDOUT ARGS...: cache-secrets.sh ARGS on a pseudo-terminal (stdin, stderr) with stdout in STDOUT;
# the user and then the token are typed once their prompt shows, everything the terminal shows goes to TRANSCRIPT.
on_tty() {
  local t=$1 o=$2
  shift 2
  python3 -I -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", "o=$1; shift; exec bash \"$@\" >\"$o\"", "_"] + sys.argv[1:])
seen = b""
def more():
    global seen
    try:
        b = os.read(fd, 4096)
    except OSError:
        b = b""
    seen += b
    return b != b""
for prompt, typed in ((os.environ["P1"], os.environ["A1"]), (os.environ["P2"], os.environ["A2"])):
    while prompt.encode() not in seen and more():
        pass
    os.write(fd, (typed + "\n").encode())
while more():
    pass
_, st = os.waitpid(pid, 0)
sys.stdout.write(seen.decode("utf-8", "replace"))
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 1)
' "$o" "$here/cache-secrets.sh" "$@" >"$t" 2>&1
}
: >"$log"
export FAKE_WANT="{\"username\":\"learner\",\"accessToken\":\"$ghp\"}" P1='GitHub user: ' A1=learner \
  P2='PAT read:packages: ' A2=$ghp
expect "ghcr of stg typed on a terminal exits 0" on_tty "$work/tty.out" "$work/tty.stdout" stg ghcr
unset P1 A1 P2 A2
expect "typed on a terminal: put-secret-value reads exactly {username, accessToken} on its stdin" \
  grep -qx 'stdin is the credential' "$log"
expect "typed on a terminal: both prompts on the terminal, neither on stdout, which holds the ok line" \
  sh -c 'grep -q "GitHub user: " "$1" && grep -q "PAT read:packages: " "$1" && ! grep -qE "GitHub user|PAT read" "$2" &&
    grep -q "^ok    entry ecr-pullthroughcache/ghcr of stg: version 01234567" "$2"' _ "$work/tty.out" "$work/tty.stdout"

# --- --print -----------------------------------------------------------------------------------------------------
: >"$log"
expect "--print stg ghcr exits 0 with stdin left unread" \
  sh -c 'printf "%s" "$2" | bash "$1" --print stg ghcr >"$3" 2>&1' _ "$here/cache-secrets.sh" "not read" "$out"
expect "--print calls nothing" test ! -s "$log"
expect "--print shows the account check, the read of the entry and the write, profile and region in each" \
  sh -c 'grep -q "^+ AWS_PROFILE=anhnv-stg aws sts get-caller-identity --output json --region ap-southeast-1$" "$1" && grep -q "^+ AWS_PROFILE=anhnv-stg aws secretsmanager describe-secret --secret-id ecr-pullthroughcache/ghcr --query Name --output text --region ap-southeast-1$" "$1" && grep -q "^+ AWS_PROFILE=anhnv-stg aws secretsmanager put-secret-value --secret-id ecr-pullthroughcache/ghcr --secret-string file:///dev/stdin --query VersionId --output text --region ap-southeast-1$" "$1"' _ "$out"
expect "--print says where the credential comes from and its form" grep -qF 'the token must be ghp_...' "$out"
expect "--print prints no prompt (reads no terminal)" sh -c '! grep -q "GitHub user: " "$1"' _ "$out"
: >"$log"
expect "--print prd dockerhub on a terminal-less run without stdin calls nothing" \
  sh -c 'bash "$1" --print prd dockerhub </dev/null >"$2" 2>&1 && [ ! -s "$3" ] && grep -q "docker-hub" "$2"' _ "$here/cache-secrets.sh" "$out" "$log"

finish
