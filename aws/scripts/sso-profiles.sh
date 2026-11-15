#!/usr/bin/env bash
# The SSO profiles of the lab's accounts in the AWS CLI's config file ($AWS_CONFIG_FILE, else ~/.aws/config), from the
# table of profiles.sh. write adds or replaces the block of each profile but anhnv-sso, which the learner makes by hand
# with its [sso-session ...] block: every profile takes the sso_session of anhnv-sso, so one aws sso login signs in to
# all of them. Nothing else of the file changes, and write reaches no account.

# check signs in with each profile of the file and compares its account with the account variable of its row. A profile
# whose account variable is not exported (eval "$(aws/scripts/accounts.sh)" sets those of the member accounts) is
# skipped by both. Exit 1 when a step FAILs; check goes on with the next profile first.

# Usage: aws/scripts/sso-profiles.sh [--print] write|check
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=aws/scripts/profiles.sh
. "$(dirname "$0")/profiles.sh"
printing && shift
case $#:${1:-} in
  1:write | 1:check) ;;
  *) fail "usage: $(basename "$0") [--print] write|check" ;;
esac
env_arg mgmt any
config=${AWS_CONFIG_FILE:-$HOME/.aws/config}
root_help="make it with aws configure sso --profile anhnv-sso, giving the SSO session a name, then run this again"

# block NAME: the lines of the first [profile NAME] block of the config file but its header, blank ones and trailing
# spaces left out; nothing when the file has no such block. A header may end in a comment after its "]", as botocore
# reads it; the comment lines after the last key belong to what follows the block, not to it.
block() {
  awk -v n="$1" '
    /^[ \t]*\[/ {
      if (done) exit
      h = $0
      sub(/\][^]]*$/, "]", h)
      gsub(/[ \t]/, "", h)
      on = (h == "[profile" n "]")
      if (on) { done = 1; next }
    }
    on && /^[ \t]*[#;]/ { sub(/[ \t\r]+$/, ""); comments = comments $0 "\n"; next }
    on && NF { sub(/[ \t\r]+$/, ""); printf "%s%s\n", comments, $0; comments = "" }
  ' "$config"
}

# want PROFILE ACCOUNT ROLE: the lines of the block write gives PROFILE.
want() {
  printf '%s\n' "sso_session = $session" "sso_account_id = $2" "sso_role_name = $3" "region = $region" "output = json"
}

# The rows write makes: every profile with a permission set.
member_rows() { awk '$3 != "-"' <<<"$profile_table"; }

write() {
  step "sso-profiles.sh write: profiles of $config"
  if printing; then
    local p v ps
    while read -r p v ps _; do
      printf '  (block [profile %s]: sso_session of [profile anhnv-sso], sso_account_id $%s, sso_role_name %s, region %s, output json)\n' \
        "$p" "$v" "$ps" "$region" >&3
    done < <(member_rows)
    return 0
  fi
  [ -f "$config" ] || fail "no $config, so no profile anhnv-sso: $root_help"
  local root
  root=$(block anhnv-sso)
  [ -n "$root" ] || fail "no [profile anhnv-sso] in $config: $root_help"
  session=$(sed -n 's/^[[:space:]]*sso_session[[:space:]]*=[[:space:]]*//p' <<<"$root" | head -n 1)
  [ -n "$session" ] ||
    fail "[profile anhnv-sso] of $config has no sso_session (the legacy SSO format, no token refresh): $root_help"
  awk -v s="$session" '{ gsub(/[ \t\r]/, "") } $0 == "[sso-session" s "]" { found = 1 } END { exit !found }' "$config" ||
    fail "no [sso-session $session] in $config, the session of anhnv-sso: $root_help"
  ok "profile anhnv-sso uses SSO session $session"

  # spec: one line per line of a block to write, "<profile><TAB><line>"; every value is checked before anything is
  # written or said of a profile, so a bad variable leaves the whole file as it was.
  local p v ps id old new changed=
  while read -r p v _; do
    id=${!v:-}
    [ -z "$id" ] || [[ $id =~ ^[0-9]{12}$ ]] || fail "$v is not the 12 digits of an account id: nothing written"
  done < <(member_rows)
  spec=$(mktemp)
  trap 'rm -f "$spec" "${tmp:-}"' EXIT
  while read -r p v ps _; do
    id=${!v:-}
    if [ -z "$id" ]; then
      skip "profile $p: $v is not exported (eval \"\$(aws/scripts/accounts.sh)\" sets it)"
      continue
    fi
    new=$(want "$p" "$id" "$ps")
    old=$(block "$p")
    if [ -z "$old" ]; then
      ok "profile $p: added, account of $v, role $ps"
      changed=1
    elif [ "$old" = "$new" ]; then
      ok "profile $p: up to date"
    elif [ "$old" = "$(want "$p" "$(awk '$1 == "sso_account_id" { print $3 }' <<<"$old")" "$ps")" ]; then
      note "profile $p: sso_account_id replaced by the account of $v"
      changed=1
    else
      note "profile $p: block replaced by the one of this script (it had other keys or values)"
      changed=1
    fi
    awk -v p="$p" '{ print p "\t" $0 }' <<<"$new" >>"$spec"
  done < <(member_rows)
  if [ -z "$changed" ]; then
    ok "$config unchanged"
    return 0
  fi

  # Each block of the spec takes the place of the profile's block, its header line and the blank and comment lines
  # after its last key kept, so the file comes out the same when nothing changes; a profile the file lacks is appended.
  tmp=$(mktemp "$(dirname "$config")/.config.XXXXXX")
  awk -v specf="$spec" '
    BEGIN {
      while ((getline l < specf) > 0) {
        i = index(l, "\t")
        n = substr(l, 1, i - 1)
        if (!(n in body)) order[++count] = n
        body[n] = body[n] substr(l, i + 1) "\n"
      }
    }
    function flush() {
      if (cur == "") return
      printf "%s\n%s%s", header, body[cur], tail
      seen[cur] = 1
      lastblank = tailblank
      cur = ""
    }
    /^[ \t]*\[/ {
      flush()
      h = $0
      sub(/\][^]]*$/, "]", h)
      gsub(/[ \t]/, "", h)
      if (h ~ /^\[profile.*\]$/) {
        n = substr(h, 9, length(h) - 9)
        if (n in body) { cur = n; header = $0; tail = ""; tailblank = 0; next }
      }
    }
    cur != "" && (!NF || /^[ \t]*[#;]/) { tail = tail $0 "\n"; tailblank = !NF; next }
    cur != "" { tail = ""; tailblank = 0; next }
    { print; lastblank = !NF }
    END {
      flush()
      for (i = 1; i <= count; i++) {
        n = order[i]
        if (seen[n]) continue
        if (NR > 0 && !lastblank) print ""
        printf "[profile %s]\n%s", n, body[n]
        lastblank = 0
      }
    }
  ' "$config" >"$tmp" || fail "write the profiles to $tmp"
  mv "$tmp" "$config" || fail "replace $config"
  ok "wrote $config"
}

check() {
  step "sso-profiles.sh check: the account behind each profile of $config"
  local p v failed=0
  while read -r p v _; do
    if ! printing; then
      if [ ! -f "$config" ] || [ -z "$(block "$p")" ]; then
        skip "profile $p: not in $config (sso-profiles.sh write)"
        continue
      fi
      if [ -z "${!v:-}" ]; then
        skip "profile $p: $v is not exported"
        continue
      fi
    fi
    (
      profile_arg "$p"
      check_account
    ) || failed=$((failed + 1))
  done <<<"$profile_table"
  [ "$failed" -eq 0 ] || fail "$failed profile(s) failed, each named above"
}

"$1"
