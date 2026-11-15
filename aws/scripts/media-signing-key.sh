#!/usr/bin/env bash
# The key pair that signs the URLs of premium/* on the media distribution, in two slots (a, b) so that a new key joins
# the key group before the old one leaves. new makes a private key outside the repository and writes its public key
# into media-signing.auto.tfvars.json of root env; activate, after the apply, writes the key's ID and the private key
# into entry svp/<env>/media-signing, which video-service reads, then deletes the private key's file.

# No value of the private key or of the entry reaches a command line (ps), stdout or stderr: openssl and jq read and
# write files in a directory of the owner alone, and put-secret-value reads the entry from such a file.
# Steps, rotation and a leaked key: docs/runbooks/media-signing-keys.md.

# Usage: aws/scripts/media-signing-key.sh [--print] stg|prd new|activate a|b
set -euo pipefail

# The runbook's form puts --print last; lib.sh reads it as the first argument.
if [ $# -gt 0 ] && [ "${!#}" = --print ]; then
  set -- --print "${@:1:$#-1}"
fi

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
usage="usage: $(basename "$0") [--print] $(env_names session) new|activate a|b"
[ $# -eq 3 ] || fail "$usage"
env_arg "$1"
case $2 in new | activate) ;; *) fail "$usage" ;; esac
case $3 in a | b) ;; *) fail "$usage (slot '$3')" ;; esac
action=$2 slot=$3
me=$(basename "$0")

key_dir=${XDG_STATE_HOME:-$HOME/.local/state}/svp/media-signing
key_file=$key_dir/$env_name-$slot.pem
tfvars=$env_root/media-signing.auto.tfvars.json
rel_tfvars=aws/envs/$env_name/media-signing.auto.tfvars.json
entry=svp/$env_name/media-signing
case $key_dir/ in
  "$infra_root"/*) fail "$key_dir is inside $infra_root: a private key never sits in the repository (set XDG_STATE_HOME elsewhere)" ;;
esac
session_dir

# The one temporary file of a run, in $key_dir: removed however the script ends.
tmp=
trap '[ -z "$tmp" ] || rm -f "$tmp"' EXIT

warn() { printing || printf 'warn  %s\n' "$*"; }

# key_dir_ready: the directory of the private keys, the owner's alone (700), made when missing.
key_dir_ready() {
  if ! printing && [ -L "$key_dir" ]; then
    fail "$key_dir is a symbolic link: the private keys go in a real directory of the owner alone"
  fi
  (umask 077 && run_ mkdir -p "$key_dir") || fail "create $key_dir"
  run_ chmod 700 "$key_dir" || fail "chmod 700 $key_dir"
}

# public_key: the public key (PEM) of $key_file; the private key stays in the file, read by openssl alone.
public_key() {
  if printing; then
    run_ openssl pkey -in "$key_file" -pubout
    pub='<public key of the file above>'
    return 0
  fi
  pub=$(openssl pkey -in "$key_file" -pubout) || fail "read the public key of $key_file with openssl"
  [[ $pub == "-----BEGIN PUBLIC KEY-----"* ]] || fail "openssl gave no PEM public key for $key_file"
}

# applied_in_session: root env has been applied in this session (its last apply came after its last destroy), so the
# key group stands with the slots of the tfvars file. A session starts with root env destroyed.
applied_in_session() {
  [ "$(awk -F '\t' '$3 == "env-apply-start" || $3 == "env-destroy-end" { e = $3 } END { print e }' \
    "$session/timeline.tsv" 2>/dev/null || true)" = env-apply-start ]
}

if [ "$action" = new ]; then
  step "$me new $slot: a key pair for slot $slot of the media key group of $env_name"
  check_account
  printing || [ ! -e "$key_file" ] ||
    fail "$key_file exists: the private key of slot $slot from an earlier new, not activated yet; $me $env_name activate $slot once root env is applied, or delete the file by hand, then this again"

  # The slots of the tfvars file, and which of them stay: in a session's first new, root env is destroyed and the
  # other slot's key is gone with it (the entry too), so it leaves the key group; once root env stands, it stays.
  current='{}'
  keep=true
  if printing; then
    printf '  (the other slot of %s stays when root env stands in this session, else it is dropped)\n' "$rel_tfvars" >&3
  else
    if [ -f "$tfvars" ]; then
      current=$(jq -ce '.media_signing_public_keys | select(type == "object")' "$tfvars" 2>/dev/null) ||
        fail "$rel_tfvars is not {\"media_signing_public_keys\": {<slot>: <PEM>}}: fix or delete it, then this again"
    fi
    if jq -e --arg s "$slot" 'has($s)' <<<"$current" >/dev/null; then
      if applied_in_session; then
        warn "slot $slot of $rel_tfvars is replaced: once applied, URLs signed with its old key fail; if slot $slot is the active one, $me $env_name activate $slot right after the apply, then bootstrap.sh $env_name secrets"
      else
        warn "slot $slot of $rel_tfvars is replaced (its key went with the root env of an earlier session)"
      fi
    fi
    others=$(jq -r --arg s "$slot" 'keys[] | select(. != $s)' <<<"$current")
    if [ -n "$others" ] && ! applied_in_session; then
      keep=false
      note "slot $(oneline <<<"$others") dropped from $rel_tfvars: root env is not applied in this session, so no URL is signed with it"
    fi
  fi

  key_dir_ready
  (umask 077 && run_ openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$key_file") ||
    fail "openssl genpkey into $key_file"
  run_ chmod 600 "$key_file" || fail "chmod 600 $key_file"
  public_key
  if printing; then
    printf '  (jq sets slot %s of %s to that public key)\n' "$slot" "$rel_tfvars" >&3
    exit 0
  fi
  tmp=$(mktemp "$key_dir/tfvars.XXXXXX") || fail "create a temporary file in $key_dir"
  jq -nS --argjson cur "$current" --argjson keep "$keep" --arg s "$slot" --arg pem "$pub" \
    '{media_signing_public_keys: ((if $keep then $cur else {} end) + {($s): ($pem + "\n")})}' >"$tmp" ||
    fail "write the public key into $tmp"
  mv -f "$tmp" "$tfvars" || fail "move $tmp to $rel_tfvars"
  tmp=
  ok "slot $slot: private key in $key_file (owner only, not shown), public key in $rel_tfvars (slots $(jq -r '.media_signing_public_keys | keys | join(" ")' "$tfvars")); next: aws/scripts/tf.sh $env_name env plan, apply, then $me $env_name activate $slot"
  exit 0
fi

step "$me activate $slot: key ID and private key of slot $slot into entry $entry"
check_account
printing || [ -f "$key_file" ] ||
  fail "no $key_file: activate deletes it once its key is in entry $entry, so slot $slot is active already or never made; for a new key: $me $env_name new $slot, aws/scripts/tf.sh $env_name env plan, apply, then this again"
ids=$(tf_ "$env_root" output -json media_signing_key_ids) ||
  fail "terraform output media_signing_key_ids of aws/envs/$env_name: is root env applied? aws/scripts/tf.sh $env_name env plan, apply, then this again"
if printing; then
  id="<slot $slot of output media_signing_key_ids>"
else
  id=$(jq -r --arg s "$slot" '.[$s] // empty' <<<"$ids" 2>/dev/null) || id=
  [ -n "$id" ] ||
    fail "slot $slot has no key in output media_signing_key_ids of aws/envs/$env_name: aws/scripts/tf.sh $env_name env plan, apply (after $me $env_name new $slot), then this again"
  [[ $id =~ ^[A-Z0-9]+$ ]] || fail "'$id' of output media_signing_key_ids is not a CloudFront public key ID"
fi

# The key CloudFront holds under that ID must be the one of the file: a new without the apply after it leaves the old
# public key in the slot, and video-service would sign URLs that CloudFront refuses.
encoded=$(aws_ cloudfront get-public-key --id "$id" --query PublicKey.PublicKeyConfig.EncodedKey --output text) ||
  fail "read CloudFront public key $id of slot $slot"
public_key
if ! printing; then
  [ "$(tr -d ' \r\n' <<<"$encoded")" = "$(tr -d ' \r\n' <<<"$pub")" ] ||
    fail "CloudFront public key $id of slot $slot is not the public key of $key_file: the apply after $me $env_name new $slot has not run; aws/scripts/tf.sh $env_name env plan, apply, then this again"
fi

key_dir_ready
if printing; then
  printf '  (jq writes {"MEDIA_SIGNING_KEY_ID": <that ID>, "MEDIA_SIGNING_KEY": <PEM of %s>} into a file of %s, owner only)\n' \
    "$key_file" "$key_dir" >&3
  aws_ secretsmanager put-secret-value --secret-id "$entry" --secret-string "file://$key_dir/entry.<random>" \
    --query VersionId --output text
  run_ rm -f "$key_file"
  exit 0
fi
tmp=$(mktemp "$key_dir/entry.XXXXXX") || fail "create a temporary file in $key_dir"
jq -n --arg id "$id" --rawfile key "$key_file" '{MEDIA_SIGNING_KEY_ID: $id, MEDIA_SIGNING_KEY: $key}' >"$tmp" ||
  fail "write the entry's JSON into $tmp"
version=$(aws_ secretsmanager put-secret-value --secret-id "$entry" --secret-string "file://$tmp" \
  --query VersionId --output text) ||
  fail "write entry $entry (the apply of aws/envs/$env_name makes it); $key_file stays: this again"
rm -f "$tmp"
tmp=
rm -f "$key_file" || fail "delete $key_file (its key is in entry $entry): delete it by hand"
ok "entry $entry: key $id of slot $slot (not shown), version $version; $key_file deleted; run aws/scripts/bootstrap.sh $env_name secrets so External Secrets syncs it now (refreshPolicy OnChange) and Reloader restarts video-service"
