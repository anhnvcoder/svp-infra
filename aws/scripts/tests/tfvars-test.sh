#!/usr/bin/env bash
# Self-test of tfvars.sh with a fake aws and terraform on PATH, on a copy of the script in a tree of its own (the real
# examples and variables.tf of the repository copied into it): no account is reached and no file of this repository
# is written. Covers each command: files written from the outputs, a line changed in place and nothing else, a second
# run that changes nothing, the old file kept when an output is empty or fails, mode 600, and no value in any output.

# Usage: aws/scripts/tests/tfvars-test.sh
#
# The checks run sh -c '...' with their values as arguments ($1, $2, ...): expanded by that shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$src/../.." && pwd)
# shellcheck source=aws/scripts/tests/testlib.sh
. "$src/tests/testlib.sh"
fake_aws
command -v python3 >/dev/null || {
  echo "FAIL  python3 not found" >&2
  exit 1
}

infra=$work/infra
script=$infra/aws/scripts/tfvars.sh
mkdir -p "$infra/aws/scripts"
cp "$src/lib.sh" "$src/tfvars.sh" "$infra/aws/scripts/"
for d in aws/org aws/accounts/stg aws/accounts/prd aws/envs/stg aws/envs/prd aws/gitops/stg aws/bootstrap github; do
  mkdir -p "$infra/$d"
  cp "$repo/$d"/*.auto.tfvars.example "$infra/$d/"
done
cp "$repo/aws/envs/stg/variables.tf" "$infra/aws/envs/stg/"
mkdir -p "$infra/aws/log-archive" "$infra/aws/security" "$infra/aws/baseline" "$infra/aws/backup"
export SVP_AWS_MGMT_ACCOUNT_ID=000000000000 SVP_AWS_STG_ACCOUNT_ID=111111111111 SVP_AWS_PRD_ACCOUNT_ID=222222222222

# The values the outputs hold; none may show up in an output of the script or in the log of the fakes.
admin_id=gid-admin-3c9e1f77
viewer_id=gid-viewer-8b2d4a10
old_admin=gid-old-admin-55aa
zone_id=Z0FAKEZONE7Q3W
old_zone=Z0OLDZONE11XY
email=alarm-5d1f@svp.example
domain=web-7c2e.svp.example
stg_zone=stg.fake-9a1b.svp.example
bucket=svp-tfstate-fake-7e4a
ns1=ns-11.awsdns-fake1.org ns2=ns-22.awsdns-fake2.net ns3=ns-33.awsdns-fake3.com ns4=ns-44.awsdns-fake4.co.uk
values="$admin_id $viewer_id $old_admin $zone_id $old_zone $email $domain $stg_zone $bucket $ns1 $ns2 $ns3 $ns4"

# The fake terraform answers output NAME of root DIR (-chdir) with the file $FAKE_TF/<DIR, / as _>.NAME, and fails
# without it; init fails while $FAKE_TF/init-fails exists. It logs the profile and the root of each call.
export FAKE_TF=$work/tf
mkdir -p "$FAKE_TF"
fake_cmd terraform '
dir= last=
for a; do case $a in -chdir=*) dir=${a#-chdir=} ;; esac; last=$a; done
echo "terraform-profile ${AWS_PROFILE:-none} $dir" >>"$FAKE_LOG"
case " $* " in
  *" output "*)
    f=$FAKE_TF/$(printf %s "$dir" | tr / _).$last
    [ -f "$f" ] || { echo "Error: Output \"$last\" not found" >&2; exit 1; }
    cat "$f" ;;
  *" init "*) [ ! -f "$FAKE_TF/init-fails" ] ;;
  *) exit 98 ;;
esac'
answer() { printf '%s' "$3" >"$FAKE_TF/$(printf %s "$1" | tr / _).$2"; }
answer aws/bootstrap backend_hcl "bucket       = \"$bucket\"
region       = \"ap-southeast-1\"
encrypt      = true
use_lockfile = true"
answer aws/accounts/stg backend_hcl "bucket = \"$bucket-stg\""
answer aws/org platform_admin_group_id "$admin_id"
answer aws/org platform_viewer_group_id "$viewer_id"
answer aws/accounts/stg zone_id "$zone_id"
answer aws/accounts/stg name_servers "[\"$ns1\",\"$ns2\",\"$ns3\",\"$ns4\"]"

# t NAME ARGS...: the script with ARGS, stdin not a terminal, output in $work/NAME.out.
n_out=0
t() {
  local o=$1
  shift
  n_out=$((n_out + 1))
  (cd "$work" && bash "$script" "$@") </dev/null >"$work/$o.out" 2>&1
}
# on_tty NAME ANSWERS ARGS...: the script on a pseudo-terminal where ANSWERS are typed.
on_tty() {
  local o=$1 a=$2
  shift 2
  ANSWERS=$a python3 -I -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
os.write(fd, os.environ["ANSWERS"].encode())
out = b""
while True:
    try:
        b = os.read(fd, 4096)
    except OSError:
        break
    if not b:
        break
    out += b
_, st = os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 1)
' bash "$script" "$@" >"$work/$o.tty" 2>&1
}
fails() { ! "$@"; }
# wrong_mgmt NAME ARGS...: t with another account in SVP_AWS_MGMT_ACCOUNT_ID than the one behind anhnv-sso.
wrong_mgmt() { (export SVP_AWS_MGMT_ACCOUNT_ID=999999999999 && t "$@"); }
has() { grep -q -- "$2" "$work/$1.out"; }
mode600() { [ -n "$(find "$1" -perm 600)" ]; }
same() { cmp -s "$1" "$2"; }
keep() { cp "$1" "$work/before"; }
kept() { cmp -s "$1" "$work/before"; }
no_tmp() { [ -z "$(find "$infra" -name '.tfvars.*')" ]; }
calls() { grep -c "^$1 " "$log" || true; }

# --- example ----------------------------------------------------------------------------------------------------------
f=$infra/aws/org/org.auto.tfvars
ex=$infra/aws/org/org.auto.tfvars.example
expect "example: copies the example of a root whose file is missing" t ex1 example aws/org
expect "example: the copy is the example" cmp -s "$f" "$ex"
expect "example: mode 600" mode600 "$f"
for k in sso_user_name name title; do
  n=$(grep -n -E "^[[:space:]]*${k}[[:space:]]*=[^#]*<" "$ex" | cut -d: -f1)
  key=$k
  [ "$k" = sso_user_name ] || key=security_contact.$k
  expect "example: lists $key at line $n as a placeholder" has ex1 "^note  aws/org/org.auto.tfvars:$n $key still holds a placeholder"
done
expect "example: lists nothing else" test "$(grep -c 'still holds a placeholder' "$work/ex1.out")" = 3
sed 's/"<user>"/"me"/' "$f" >"$work/edited" && cat "$work/edited" >"$f"
keep "$f"
expect "example: a second run keeps the file as it is" t ex2 example aws/org
expect "example: never writes over the file" kept "$f"
expect "example: says the file is left" has ex2 'org.auto.tfvars exists: left as it is'
expect "example: still lists the placeholders left" test "$(grep -c 'still holds a placeholder' "$work/ex2.out")" = 2
expect "example: example.auto.tfvars.example of a session root becomes <env>.auto.tfvars" t ex3 example aws/gitops/stg
expect "example: aws/gitops/stg/stg.auto.tfvars written" test -f "$infra/aws/gitops/stg/stg.auto.tfvars"
expect "example: no placeholder in it" has ex3 'aws/gitops/stg/stg.auto.tfvars: no placeholder <...> left'
expect "example: an unknown root FAILs" fails t ex4 example aws/nowhere
expect "example: a path that climbs out FAILs" fails t ex5 example aws/../aws/org
expect "example: an absolute path FAILs" fails t ex6 example "$infra/aws/org"
expect "example: a root with no example FAILs" fails t ex7 example aws/scripts
expect "example: no fake was called" test ! -s "$log"

# --- init before any backend.hcl --------------------------------------------------------------------------------------
: >"$log"
expect "init: FAILs without aws/backend.hcl" fails t in1 init
expect "init: ... before any terraform or aws" test "$(calls terraform)$(calls aws)" = 00

# --- backend ----------------------------------------------------------------------------------------------------------
b=$infra/aws/backend.hcl
: >"$log"
expect "backend mgmt: runs" t be1 backend mgmt
expect "backend mgmt: aws/backend.hcl is output backend_hcl of aws/bootstrap" \
  sh -c 'printf "%s\n" "$(cat "$2")" | cmp -s - "$1"' _ "$b" "$FAKE_TF/aws_bootstrap.backend_hcl"
expect "backend mgmt: mode 600" mode600 "$b"
expect "backend mgmt: account checked with anhnv-sso first" \
  sh -c 'head -n 1 "$1" | grep -q "^aws sts get-caller-identity .*--region ap-southeast-1"' _ "$log"
expect "backend mgmt: terraform of aws/bootstrap with anhnv-sso" grep -q '^terraform-profile anhnv-sso aws/bootstrap$' "$log"
keep "$b"
expect "backend mgmt: a second run" t be2 backend mgmt
expect "backend mgmt: ... leaves the file unchanged" has be2 'aws/backend.hcl: output backend_hcl of aws/bootstrap already as written, file unchanged'
expect "backend mgmt: ... same content" kept "$b"
: >"$log"
expect "backend stg: runs" t be3 backend stg
expect "backend stg: aws/backend-stg.hcl from aws/accounts/stg with anhnv-stg" \
  sh -c 'grep -q "^terraform-profile anhnv-stg aws/accounts/stg$" "$1" && test -f "$2"' _ "$log" "$infra/aws/backend-stg.hcl"
expect "backend stg: mode 600" mode600 "$infra/aws/backend-stg.hcl"
answer aws/bootstrap backend_hcl ''
expect "backend: an empty output FAILs" fails t be4 backend mgmt
expect "backend: ... and keeps the old file" kept "$b"
rm "$FAKE_TF/aws_bootstrap.backend_hcl"
expect "backend: a failed output FAILs" fails t be5 backend mgmt
expect "backend: ... and keeps the old file" kept "$b"
answer aws/bootstrap backend_hcl 'Warning: No outputs found'
expect "backend: an output without bucket FAILs" fails t be6 backend mgmt
expect "backend: ... and keeps the old file" kept "$b"
: >"$log"
expect "backend: another account behind the profile FAILs" \
  fails wrong_mgmt be7 backend mgmt
expect "backend: ... before any terraform" test "$(calls terraform)" = 0
expect "backend: an env outside env_table FAILs" fails t be8 backend dev
expect "backend: no temporary file left" no_tmp

# --- init -------------------------------------------------------------------------------------------------------------
: >"$log"
expect "init: runs" t in2 init
want='-chdir=aws/bootstrap init -input=false -reconfigure -backend-config=../backend.hcl
-chdir=aws/org init -input=false -reconfigure -backend-config=../backend.hcl
-chdir=aws/log-archive init -input=false -reconfigure -backend-config=../backend.hcl
-chdir=aws/security init -input=false -reconfigure -backend-config=../backend.hcl
-chdir=aws/baseline init -input=false -reconfigure -backend-config=../backend.hcl
-chdir=aws/backup init -input=false -reconfigure -backend-config=../backend.hcl
-chdir=github init -input=false -reconfigure -backend-config=../aws/backend.hcl'
expect "init: each management root, in order, with its -backend-config" \
  test "$(sed -n 's/^terraform //p' "$log")" = "$want"
expect "init: every one with anhnv-sso" test "$(grep -c '^terraform-profile anhnv-sso ' "$log")" = 7
expect "init: one ok per root" test "$(grep -c '^ok    terraform init -reconfigure of ' "$work/in2.out")" = 7
touch "$FAKE_TF/init-fails"
expect "init: a failed init FAILs" fails t in3 init
rm "$FAKE_TF/init-fails"

# --- groups -----------------------------------------------------------------------------------------------------------
g=$infra/aws/accounts/stg/stg.auto.tfvars
expect "groups: FAILs while aws/accounts/stg has no tfvars" fails t gr0 groups stg
t gr-ex example aws/accounts/stg
sed "s/^zone_name .*/zone_name        = \"$stg_zone\"/" "$g" >"$work/edited" && cat "$work/edited" >"$g"
keep "$g"
: >"$log"
expect "groups stg: runs" t gr1 groups stg
expect "groups stg: aws/org read with anhnv-sso" grep -q '^terraform-profile anhnv-sso aws/org$' "$log"
expect "groups stg: the admin line has the id, its alignment kept" \
  grep -qx "platform_admin_group_id  = \"$admin_id\"" "$g"
expect "groups stg: the viewer line has the id" grep -qx "platform_viewer_group_id = \"$viewer_id\"" "$g"
expect "groups stg: every other line unchanged, in order, at the same line numbers" \
  bash -c 'diff <(sed -E "s/^(platform_(admin|viewer)_group_id).*/\1/" "$1") <(sed -E "s/^(platform_(admin|viewer)_group_id).*/\1/" "$2") >/dev/null' _ "$g" "$work/before"
expect "groups stg: mode 600" mode600 "$g"
keep "$g"
expect "groups stg: a second run" t gr2 groups stg
expect "groups stg: ... changes nothing" kept "$g"
grep -v -E '^platform_(admin|viewer)_group_id' "$g" >"$work/edited" && cat "$work/edited" >"$g"
expect "groups stg: lines missing are added" t gr3 groups stg
expect "groups stg: ... at the end, one each" \
  sh -c 'tail -n 2 "$1" | grep -c -E "^platform_(admin|viewer)_group_id = \"" | grep -qx 2' _ "$g"
printf 'platform_admin_group_id = "%s"\n' "$old_admin" >>"$g"
keep "$g"
expect "groups stg: a variable set twice FAILs" fails t gr4 groups stg
expect "groups stg: ... file unchanged" kept "$g"
sed '$d' "$g" >"$work/edited" && cat "$work/edited" >"$g"
keep "$g"
answer aws/org platform_viewer_group_id ''
expect "groups: an empty output FAILs" fails t gr5 groups stg
expect "groups: ... file unchanged" kept "$g"
answer aws/org platform_viewer_group_id "$viewer_id"
expect "groups: an env without session roots FAILs" fails t gr6 groups mgmt

# --- env --------------------------------------------------------------------------------------------------------------
e=$infra/aws/envs/stg/stg.auto.tfvars
cat >"$e" <<EOF
# Values of the stg session.
hosted_zone_id = "$old_zone"
domain         = "$domain"
eks_public_access_cidrs = [
  "203.0.113.7/32",
]
alarm_email    = "$email"
acme_email = "$email"
msk_password_version = 3
grafana_workspace_id = "g-0000000000"
EOF
cat >"$work/want" <<EOF
# Values of the stg session.
hosted_zone_id = "$zone_id"
domain         = "$domain"
alarm_email    = "$email"
msk_password_version = 3
EOF
: >"$log"
expect "env stg: runs" t en1 env stg
expect "env stg: zone id replaced, the three undeclared variables (one of several lines) removed, the rest kept" \
  same "$e" "$work/want"
expect "env stg: zone_id of aws/accounts/stg read with anhnv-stg" grep -q '^terraform-profile anhnv-stg aws/accounts/stg$' "$log"
expect "env stg: names what it removed" has en1 'removed: eks_public_access_cidrs acme_email grafana_workspace_id'
expect "env stg: counts the three lines" has en1 'stg.auto.tfvars: 3 of hosted_zone_id, domain, alarm_email'
expect "env stg: mode 600" mode600 "$e"
expect "env stg: a second run" t en2 env stg
expect "env stg: ... changes nothing" same "$e" "$work/want"
expect "env stg: ... and says so" has en2 'already as written, file unchanged'
grep -v '^alarm_email' "$e" >"$work/edited" && cat "$work/edited" >"$e"
keep "$e"
: >"$log"
expect "env stg: no terminal and no alarm_email FAILs" fails t en3 env stg
expect "env stg: ... names the variable" has en3 'has no alarm_email and stdin is not a terminal'
expect "env stg: ... file unchanged" kept "$e"
expect "env stg: ... before any aws or terraform" test "$(calls terraform)$(calls aws)" = 00
rm "$e"
expect "env stg: no terminal and no file FAILs" fails t en4 env stg
expect "env stg: ... and writes no file" test ! -e "$e"
expect "env stg: on a terminal, asks domain and alarm_email" on_tty en5 "$domain
$email
" env stg
printf '%s\n' "hosted_zone_id = \"$zone_id\"" "domain = \"$domain\"" "alarm_email = \"$email\"" >"$work/want"
expect "env stg: ... and writes the three lines in order" same "$e" "$work/want"
expect "env stg: ... mode 600" mode600 "$e"
rm "$e"
expect "env stg: a typed domain that is not a DNS name FAILs" fails on_tty en6 'not a domain
' env stg
expect "env stg: ... and writes no file" test ! -e "$e"
cp "$work/want" "$e"
keep "$e"
answer aws/accounts/stg zone_id 'not-a-zone'
expect "env stg: an output that is not a zone id FAILs" fails t en7 env stg
expect "env stg: ... file unchanged" kept "$e"
answer aws/accounts/stg zone_id ''
expect "env stg: an empty output FAILs" fails t en8 env stg
expect "env stg: ... file unchanged" kept "$e"
answer aws/accounts/stg zone_id "$zone_id"

# --- delegation -------------------------------------------------------------------------------------------------------
p=$infra/aws/accounts/prd/prd.auto.tfvars
expect "delegation: FAILs while aws/accounts/prd has no tfvars" fails t de0 delegation
t de-ex example aws/accounts/prd
keep "$p"
: >"$log"
expect "delegation: runs" t de1 delegation
expect "delegation: name_servers of aws/accounts/stg read with anhnv-stg" \
  grep -q '^terraform-profile anhnv-stg aws/accounts/stg$' "$log"
printf '%s\n' 'delegated_subdomains = {' "  \"$stg_zone\" = [\"$ns1\", \"$ns2\", \"$ns3\", \"$ns4\"]" '}' >"$work/block"
expect "delegation: the block is the zone of stg and its four name servers" \
  sh -c 'sed -n "/^delegated_subdomains/,/^}/p" "$1" | cmp -s - "$2"' _ "$p" "$work/block"
expect "delegation: every line before the block unchanged" \
  bash -c 'diff <(sed "/^delegated_subdomains/,\$d" "$1") <(sed "/^delegated_subdomains/,\$d" "$2") >/dev/null' _ "$p" "$work/before"
expect "delegation: the block replaced, not added" test "$(grep -c '^delegated_subdomains' "$p")" = 1
expect "delegation: mode 600" mode600 "$p"
keep "$p"
expect "delegation: a second run" t de2 delegation
expect "delegation: ... changes nothing" kept "$p"
sed '/^delegated_subdomains/,$d' "$p" >"$work/edited" && cat "$work/edited" >"$p"
expect "delegation: a file without the block" t de3 delegation
expect "delegation: ... gets it at the end" sh -c 'tail -n 3 "$1" | cmp -s - "$2"' _ "$p" "$work/block"
keep "$p"
answer aws/accounts/stg name_servers "[\"$ns1\",\"$ns2\",\"$ns3\"]"
expect "delegation: three name servers FAIL" fails t de4 delegation
expect "delegation: ... file unchanged" kept "$p"
answer aws/accounts/stg name_servers 'not json'
expect "delegation: an output that is not a JSON list FAILs" fails t de5 delegation
expect "delegation: ... file unchanged" kept "$p"

# --- bump -------------------------------------------------------------------------------------------------------------
e=$infra/aws/envs/stg/stg.auto.tfvars
printf '%s\n' "hosted_zone_id = \"$zone_id\"" "msk_password_version = 3" "alarm_email = \"$email\"" >"$e"
: >"$log"
expect "bump stg msk: runs" t bu1 bump stg msk
expect "bump stg msk: 3 becomes 4 on its own line, the rest unchanged" \
  same "$e" <(printf '%s\n' "hosted_zone_id = \"$zone_id\"" "msk_password_version = 4" "alarm_email = \"$email\"")
expect "bump stg msk: says from 3 to 4" has bu1 'msk_password_version from 3 to 4 written'
expect "bump stg valkey: a missing line" t bu2 bump stg valkey
expect "bump stg valkey: ... is added as the default of variables.tf plus one" \
  sh -c 'tail -n 1 "$1" | grep -qx "valkey_password_version = 2"' _ "$e"
expect "bump: no aws or terraform" test "$(calls terraform)$(calls aws)" = 00
expect "bump: mode 600" mode600 "$e"
sed 's/^msk_password_version.*/msk_password_version = "4"/' "$e" >"$work/edited" && cat "$work/edited" >"$e"
keep "$e"
expect "bump: a value that is not a whole number FAILs" fails t bu3 bump stg msk
expect "bump: ... file unchanged" kept "$e"
expect "bump: a group other than msk, valkey FAILs" fails t bu4 bump stg rds
expect "bump: an env without session roots FAILs" fails t bu5 bump mgmt msk
rm "$e"
expect "bump: no file FAILs" fails t bu6 bump stg msk

# --- --print ----------------------------------------------------------------------------------------------------------
(cd "$infra" && find . -type f -exec cksum {} + | sort) >"$work/tree.before"
: >"$log"
for c in 'example aws/envs/prd' 'backend prd' 'init' 'groups prd' 'env prd' 'delegation' 'bump prd valkey'; do
  # shellcheck disable=SC2086 # the words of the command
  expect "--print $c: runs" t "pr-${c%% *}" --print $c
done
expect "--print: no aws, no terraform" test ! -s "$log"
expect "--print: no file written" sh -c 'tree() { (cd "$1" && find . -type f -exec cksum {} + | sort); }; tree "$1" | cmp -s - "$2"' \
  _ "$infra" "$work/tree.before"
expect "--print backend prd: shows the output command with the profile" \
  has pr-backend '^+ AWS_PROFILE=anhnv-prd terraform -chdir=aws/accounts/prd output -raw backend_hcl'
expect "--print init: shows the seven inits" test "$(grep -c '^+ AWS_PROFILE=anhnv-sso terraform -chdir=.* init ' "$work/pr-init.out")" = 7
expect "--print groups prd: shows the two outputs of aws/org" \
  test "$(grep -c '^+ AWS_PROFILE=anhnv-sso terraform -chdir=aws/org output -raw platform_' "$work/pr-groups.out")" = 2
expect "--print env prd: shows zone_id of aws/accounts/prd" \
  has pr-env '^+ AWS_PROFILE=anhnv-prd terraform -chdir=aws/accounts/prd output -raw zone_id'
expect "--print delegation: shows name_servers of aws/accounts/stg" \
  has pr-delegation '^+ AWS_PROFILE=anhnv-stg terraform -chdir=aws/accounts/stg output -json name_servers'
expect "--print: no ok, FAIL or note line" sh -c '! grep -h -E "^(ok|FAIL|note) " "$@"' _ "$work"/pr-*.out

# --- nothing leaks ----------------------------------------------------------------------------------------------------
for v in $values; do
  expect "no output and no log line holds $v" no_leak "$v" "$work"/*.out "$log"
done
expect "no temporary file left anywhere" no_tmp

finish
