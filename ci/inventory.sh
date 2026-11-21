#!/usr/bin/env bash
# Inventory of the roots: what each root (each env of aws/accounts, aws/envs, aws/gitops) creates on an empty account,
# counted from a plan of terraform test against mock providers. write regenerates docs/reference/inventory.md and
# docs/diagrams/inventory/; check generates into a temporary directory and fails, naming the file, on any difference.

# The plans run on a copy of the files git tracks below aws/ and github/, minus every file that may hold personal
# values (denied below), in a container without network or credential; only init, in a container of its own, reaches
# the registries. ci/inventory/<family>.tftest.hcl holds the mocks of a root, notes() below what they assume.
# A mock plan, not a hand-written table or terraform-docs: those drift from the code or miss for_each and count.

# Usage: ci/inventory.sh write|check
#
# The jq programs and the page's text hold literal $ signs and backticks.
# shellcheck disable=SC2016
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
: "${TERRAFORM_IMAGE:?set by make inventory}" "${D2_IMAGE:?set by make inventory}"
page=docs/reference/inventory.md
diagrams=docs/diagrams/inventory
cache=$repo/.plugin-cache

# No credential reaches a container: no AWS_* variable lives on in this shell, and docker gets no -e of one.
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep '^AWS_' || true)
unset DOCKER_DEFAULT_PLATFORM

ROOTS=(aws/bootstrap aws/org aws/log-archive aws/security aws/baseline aws/backup aws/accounts/stg aws/accounts/prd
  aws/envs/stg aws/envs/prd aws/gitops/stg aws/gitops/prd github)

fail() {
  echo "FAIL: inventory: $*" >&2
  exit 1
}

# denied PATH: whether the copy leaves PATH out. git already leaves out what .gitignore lists; this list holds even for
# a file someone added with git add -f. Test files of the repository are left out too: only the inventory's run.
denied() {
  case /$1 in
    *.example) return 1 ;;
    */.terraform/* | */.session/* | */.envrc | *.tfstate | *.tfstate.* | *.tfplan | */tfplan) return 0 ;;
    *.auto.tfvars | *.auto.tfvars.json | */terraform.tfvars | */terraform.tfvars.json) return 0 ;;
    */backend.hcl | */backend-*.hcl | */override.tf | */override.tf.json | *_override.tf | *_override.tf.json) return 0 ;;
    *.tftest.hcl | *.tftest.json) return 0 ;;
    *) return 1 ;;
  esac
}

# copy_tree DIR: the files git tracks (and new ones it does not ignore) below aws/ and github/ into DIR, regular files
# only: a symbolic link could point outside the repository.
copy_tree() {
  local dir=$1 f
  while IFS= read -r -d '' f; do
    [ -f "$repo/$f" ] && [ ! -L "$repo/$f" ] || continue
    denied "$f" && continue
    if ! mkdir -p "$dir/$(dirname "$f")" || ! cp "$repo/$f" "$dir/$f"; then fail "copy $f"; fi
  done < <(git -C "$repo" ls-files -z --cached --others --exclude-standard -- aws/ github/)
  while IFS= read -r f; do
    if denied "${f#"$dir"/}"; then fail "the copy holds $f, which the inventory never reads"; fi
  done < <(find "$dir" -type f)
}

# check_roots: a directory of the copy with a *.tf file outside modules/ is a root, as LIST_DIRS of the Makefile finds
# them; one missing from ROOTS would never be counted.
check_roots() {
  local d r found rc=0
  while IFS= read -r d; do
    found=
    for r in "${ROOTS[@]}"; do [ "$r" != "$d" ] || found=1; done
    [ -n "$found" ] || { echo "FAIL: inventory: $d is a Terraform root missing from ROOTS of ci/inventory.sh" >&2 && rc=1; }
  done < <(cd "$copy" && find . -name '*.tf' | sed 's|/[^/]*$||; s|^\./||' | grep -v -E '(^|/)modules(/|$)' | sort -u)
  [ "$rc" = 0 ] || exit 1
}

# family ROOT: the name of ROOT's files in ci/inventory/; the env roots of one directory share them.
family() {
  local r=${1#aws/}
  case $r in accounts/* | envs/* | gitops/*) r=${r%/*} ;; esac
  echo "${r//\//-}"
}
slug() {
  local r=${1#aws/}
  echo "${r//\//-}"
}

# var_files ROOT: the -var-file arguments of ROOT, relative to it: <env>.tfvars when the root has one, then every
# committed *.auto.tfvars.example, whose values stand in for the personal ones that no committed file holds.
var_files() {
  local root=$1 f
  f=$copy/$root/${root##*/}.tfvars
  [ ! -f "$f" ] || echo "-var-file=${root##*/}.tfvars"
  for f in "$copy/$root"/*.auto.tfvars.example; do [ ! -f "$f" ] || echo "-var-file=$(basename "$f")"; done
}

# The plugin cache has one writer at a time, as with make test (CACHE_LOCK of the Makefile).
lock() {
  local n=0
  mkdir -p "$cache/terraform" "$cache/tflint" || fail "mkdir $cache"
  until mkdir "$cache/lock" 2>/dev/null; do
    n=$((n + 1))
    [ $n -lt 600 ] || fail "$cache/lock held for 10 minutes; remove it if no make runs"
    sleep 1
  done
  locked=1
}
unlock() {
  [ -z "$locked" ] || rmdir "$cache/lock"
  locked=
}

TF_RUN=(docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e CHECKPOINT_DISABLE=1 -e TF_IN_AUTOMATION=1
  -e TF_DATA_DIR=/tfdata)

# plan ROOT: the plan JSON of ROOT's run "inventory" into $work/plan.json.
plan() {
  local root=$1 data rc=0 out=$work/test.json
  data=$(mktemp -d "$work/data.XXXXXX")
  [ -f "$repo/ci/inventory/$(family "$root").tftest.hcl" ] || fail "no ci/inventory/$(family "$root").tftest.hcl for $root"
  mkdir -p "$copy/$root/tests"
  cp "$repo/ci/inventory/$(family "$root").tftest.hcl" "$copy/$root/tests/inventory.tftest.hcl"
  lock
  if ! "${TF_RUN[@]}" -e TF_PLUGIN_CACHE_DIR=/plugin-cache -e TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=1 \
    -v "$data:/tfdata" -v "$cache/terraform:/plugin-cache" -v "$copy:/src:ro" -w "/src/$root" \
    "$TERRAFORM_IMAGE" init -backend=false -input=false -no-color -lockfile=readonly >"$work/init.log" 2>&1; then
    cat "$work/init.log" >&2
    fail "terraform init $root"
  fi
  unlock
  # shellcheck disable=SC2046 # one -var-file argument per line, without blanks
  "${TF_RUN[@]}" --network none -v "$data:/tfdata" -v "$cache/terraform:/plugin-cache:ro" -v "$copy:/src:ro" \
    -w "/src/$root" "$TERRAFORM_IMAGE" test -json -verbose -no-color $(var_files "$root") >"$out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e 'select(.type == "test_summary") | .test_summary.status == "pass"' "$out" >/dev/null; then
    jq -r 'select(.["@level"] == "error") | .["@message"] + "\n" + (.diagnostic.detail // "")' "$out" >&2 ||
      cat "$out" >&2
    fail "terraform test of $root with ci/inventory/$(family "$root").tftest.hcl"
  fi
  jq -c 'select(.type == "test_plan" and .["@testrun"] == "inventory") | .test_plan' "$out" >"$work/plan.json"
  [ -s "$work/plan.json" ] || fail "terraform test of $root printed no plan of run \"inventory\""
}

# records ROOT: $work/plan.json as "root<TAB>part<TAB>type<TAB>action" lines, one per managed resource. The part is the
# root's module call, or the .tf file of the root that declares the resource. An import counts apart from a create.
records() {
  local root=$1 module type name action file
  jq -r '.resource_changes[]? | select(.mode == "managed")
    | [((.module_address // "" | capture("^(?<m>module\\.[A-Za-z0-9_-]+)") | .m)? // "-"), .type, .name,
       (if .change.importing then "import" else .change.actions | if . == ["create"] then "create"
         else join("-") end end)] | @tsv' "$work/plan.json" >"$work/changes.tsv"
  while IFS=$'\t' read -r module type name action; do
    if [ "$module" = - ]; then
      file=$(grep -lE "^resource \"$type\" \"$name\"" "$copy/$root"/*.tf | head -n 1) || true
      [ -n "$file" ] || fail "$root: no .tf file declares resource $type.$name"
      module=$(basename "$file")
    fi
    [ "$action" = create ] || [ "$action" = import ] ||
      fail "$root: $module $type.$name would $action on an empty account; only create and import are expected"
    printf '%s\t%s\t%s\t%s\n' "$root" "$module" "$type" "$action"
  done <"$work/changes.tsv"
}

# The AWS service of a resource type: the label of the diagrams and the page, and the icon of docs/diagrams/icons/.
# A type of another provider has no icon. A new AWS type outside this table fails, so its icon is chosen once.
SERVICES='def service:
  [["^aws_s3_", "S3", "s3"], ["^aws_kms_", "KMS", "kms"], ["^aws_(iam_|accessanalyzer_)", "IAM", "iam"],
   ["^aws_ecr_", "ECR", "ecr"], ["^aws_prometheus_", "AMP", "amp"], ["^aws_grafana_", "AMG", "amg"],
   ["^aws_cloudwatch_event_", "EventBridge", "eventbridge"], ["^aws_cloudwatch_", "CloudWatch", "cloudwatch"],
   ["^aws_xray_", "X-Ray", "xray"], ["^aws_route53_", "Route 53", "route53"], ["^aws_budgets_", "Budgets", "budgets"],
   ["^aws_ce_", "Cost Explorer", "cost-explorer"], ["^aws_cloudtrail", "CloudTrail", "cloudtrail"],
   ["^aws_(organizations_|account_)", "Organizations", "organizations"],
   ["^aws_(ssoadmin_|identitystore_)", "Identity Center", "identity-center"], ["^aws_guardduty_", "GuardDuty", "guardduty"],
   ["^aws_inspector2_", "Inspector", "inspector"], ["^aws_securityhub_", "Security Hub", "security-hub"],
   ["^aws_config_", "Config", "config"], ["^aws_backup_", "Backup", "backup"], ["^aws_sns_", "SNS", "sns"],
   ["^aws_sqs_", "SQS", "sqs"], ["^aws_secretsmanager_", "Secrets Manager", "secrets-manager"],
   ["^aws_ebs_", "EBS", "ebs"],
   ["^aws_(vpc|subnet|route_table|route$|nat_gateway|eip$|internet_gateway|security_group|flow_log|network_acl|default_)",
    "VPC", "vpc"],
   ["^aws_(instance$|launch_template$|ec2_)", "EC2", "ec2"], ["^aws_eks_", "EKS", "eks"], ["^aws_db_", "RDS", "rds"],
   ["^aws_msk_", "MSK", "msk"], ["^aws_elasticache_", "ElastiCache", "elasticache"],
   ["^aws_(cloudfront_|pricingplanmanager_)", "CloudFront", "cloudfront"], ["^aws_wafv2_", "WAF", "waf"],
   ["^aws_lb", "ELB", "elb"], ["^aws_acm_", "ACM", "acm"], ["^aws_media_convert_", "MediaConvert", "mediaconvert"],
   ["^aws_appautoscaling_", "Auto Scaling", "auto-scaling"],
   ["^github_", "GitHub", null], ["^kubernetes_", "Kubernetes", null], ["^helm_", "Helm", null],
   ["^(random|time|null|tls|cloudinit)_", "Terraform", null]] as $t
  | . as $type | first($t[] | select(. as $r | $type | test($r[0]))) // null
  | if . == null then error("no service for resource type \($type): add it to SERVICES of ci/inventory.sh")
    else {name: .[1], icon: .[2]} end;'

# The records of one root, from $work/records.tsv, as a JSON array.
root_records() {
  jq -R -s -c --arg root "$1" "$SERVICES"'
    [split("\n")[] | select(length > 0) | split("\t") | select(.[0] == $root)
     | {part: .[1], type: .[2], action: .[3], service: (.[2] | service)}]' "$work/records.tsv"
}

# The page's opening, then what the fake values of each root family assume (ci/inventory/<family>.tftest.hcl), in
# Vietnamese like every page of docs/: what a reader must know to trust or adjust the counts.
intro() {
  cat <<'EOF'
# Tài nguyên mỗi root tạo trên account trống

Trang này đếm, cho mỗi root Terraform (mỗi env của root có env), các tài nguyên mà lần `apply` đầu tiên tạo trên account chưa có gì
của root đó, chia theo phần và theo loại, kèm một sơ đồ. Đọc trước khi chạy một root để biết plan đúng ra bao nhiêu `to add` và chúng
thuộc dịch vụ nào. Trang và sơ đồ sinh bằng `make inventory` từ plan của `terraform test` trên provider giả: offline, không credential,
không phí. Không sửa tay: `make inventory-check` ở CI đỏ khi trang hay sơ đồ lệch code. Lý do chọn cách này, và các phương án đã bỏ:
[ADR-0081](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0081-terraform-inventory.md).

## Cách đọc

- Dòng `Plan: …` là dòng tóm tắt `terraform plan` in ra trên account trống; `to import` là tài nguyên root nhận quản qua khối `import`
  thay vì tạo.
- **Phần**: lời gọi module cấp root (`module.<tên>`); tài nguyên khai báo thẳng trong root thì là file `.tf` khai báo nó.
- Bảng theo loại đếm mọi bản của `count`, `for_each`; cột dịch vụ là dịch vụ AWS của icon trên sơ đồ.
- Sơ đồ: mỗi khối một phần, tiêu đề ghi số tài nguyên của phần; mỗi icon một dịch vụ AWS kèm số tài nguyên của dịch vụ đó trong phần.
  Icon lấy từ bộ AWS Architecture Icons ([nguồn và bản](../diagrams/README.md#icon)).

## Giới hạn

- Số là của **account trống chạy lần đầu**. Nâng cấp account đã chạy root: lấy bảng của root trừ phần đã có; plan thật chỉ hiện phần
  còn thiếu cùng các thay đổi.
- Giá trị: biến từ `<env>.tfvars` đã commit, không có thì từ `*.auto.tfvars.example`; cờ chi phí từ `aws/paid-features.json` của
  repo; `session_open` theo mặc định (`false`); account id giả dạng `000000000000`, tên miền `svp.example`. Đổi cờ hay `<env>.tfvars`
  thì số đổi theo: chạy lại `make inventory` trong cùng PR.
- Data source trả giá trị giả của `ci/inventory/<root>.tftest.hcl` (provider giả, không đọc account). Mỗi root dưới đây nêu giả định
  nào của giá trị giả quyết định số.
EOF
}

notes() {
  case $1 in
    bootstrap) echo '- Account management chưa có state bucket hay budget. Số không phụ thuộc giá trị giả: mỗi email của `budget_emails`
  chỉ thêm một người nhận trong budget và anomaly subscription.' ;;
    org) echo '- Tổ chức chưa có; IAM Identity Center đã bật (một instance, việc tay trước root này) và có user `sso_user_name`.
- `account_emails` theo file ví dụ: năm account thành viên.' ;;
    log-archive) echo '- Account log archive trống, trong tổ chức của `aws/org`. Số không phụ thuộc giá trị giả.' ;;
    security) echo '- Tổ chức có đủ năm account thành viên `ACTIVE`; detector GuardDuty của hai region đã có (`aws/org` giao delegated
  admin), Inspector tự bật quét ECR cho account security nên `aws_inspector2_enabler.security` là import.
- Số member của Inspector và số association của Security Hub theo số account và cờ `inspector_ecr`, `security_hub` của
  `aws/paid-features.json`.' ;;
    baseline) echo '- Sáu account (management, log archive, security, backup, stg, prd), chưa account nào có baseline; region nhà
  `ap-southeast-1`. Cờ `config_recording` theo `aws/paid-features.json`: chỉ account vắng khỏi file (security) ghi AWS Config.' ;;
    backup) echo '- Account backup trống, trong tổ chức của `aws/org`. Số không phụ thuộc giá trị giả.' ;;
    accounts) echo '- Account env trống. Cờ theo `aws/paid-features.json`: `managed_grafana` là `off` nên không có phần AMG.
- stg và prd khác nhau ở DNSSEC, query log và alarm của zone prd, số role CI, role Spot của stg. `delegated_subdomains` của
  `prd.auto.tfvars.example` uỷ quyền zone stg, nên prd có thêm một `aws_route53_record` (bản ghi NS `delegation`).' ;;
    envs) echo '- Account env đã chạy `aws/accounts/<env>`: workspace AMP, log group, key, 8 repo ECR phát hành, 5 rule pull-through cache.
- Region có ba zone, mọi endpoint interface có ở cả ba; một khoá ký URL media (slot `a`). Cỡ env (zone, NAT, endpoint, node, Multi-AZ)
  từ `<env>.tfvars`.' ;;
    gitops) echo '- Cluster của `aws/envs/<env>` đã chạy, chưa có gì của bootstrap. 11 namespace: `argocd` cùng mười namespace mà chart
  `svp-cluster` với `platforms/eks/svp-cluster.yaml` của svp-gitops sinh ra, chép vào giá trị giả: đổi danh sách đó thì sửa
  `ci/inventory/gitops.tftest.hcl`.
- Tài nguyên Kubernetes, Helm không có icon AWS: sơ đồ ghi chúng bằng chữ.' ;;
    github) echo '- State trống nên mỗi repo hiện là `create`. Repo đã có trên GitHub thì nhận quản bằng khối `import` tạm
  ([`github-setup.md`](../runbooks/github-setup.md)), không tạo lại.' ;;
    *) fail "no notes for $1 in ci/inventory.sh" ;;
  esac
}

# section ROOT LEVEL [NOTES]: the Markdown section of ROOT, headed at LEVEL (## or ###), from its records on stdin.
section() {
  local root=$1 level=$2 records
  records=$(cat)
  printf '%s `%s`\n\n' "$level" "$root"
  [ -z "${3:-}" ] || printf '%s\n\n' "$3"
  jq -r --arg root "$root" --arg slug "$(slug "$root")" '
    def count($k): group_by(.[$k]) | map({key: .[0][$k], n: length, i: ([.[] | select(.action == "import")] | length),
      service: .[0].service.name});
    def imports: if .i > 0 then " (\(.i) import)" else "" end;
    ([.[] | select(.action == "import")] | length) as $i | ([.[] | select(.action == "create")] | length) as $c
    | "`Plan: \(if $i > 0 then "\($i) to import, " else "" end)\($c) to add, 0 to change, 0 to destroy.`\n",
      "<picture>",
      "  <source media=\"(prefers-color-scheme: dark)\" srcset=\"../diagrams/inventory/\($slug)-dark.svg\">",
      "  <img src=\"../diagrams/inventory/\($slug).svg\" alt=\"Tài nguyên \($root) tạo trên account trống, theo phần\">",
      "</picture>\n",
      "| Phần | Tài nguyên |", "| --- | ---: |",
      (count("part")[] | "| `\(.key)` | \(.n)\(imports) |"),
      "",
      "| Loại | Dịch vụ | Số |", "| --- | --- | ---: |",
      (count("type")[] | "| `\(.key)` | \(.service) | \(.n)\(imports) |")' <<<"$records"
}

# diagram ROOT: the D2 source of ROOT's diagram, from its records on stdin: one block per part, titled with its count,
# holding one icon per AWS service with the service's count; a service of another provider is a line of text.
diagram() {
  jq -r --arg root "$1" '
    def cols($n; $max): [($n | sqrt | ceil), $max, $n] | min;
    # The label sits on the light fill of the block: dark text in both themes, as class sub has.
    "style: {font-color: \"#1A1A1A\"; font-size: 13; bold: false}" as $label |
    (group_by(.part) | map({part: .[0].part, n: length,
      services: (group_by(.service.name) | map({name: .[0].service.name, icon: .[0].service.icon, n: length}))})) as $parts
    | ($parts | length) as $np | cols($np; 4) as $c
    | "# Generated by make inventory from a mock plan of \($root): change ci/inventory.sh or the root, never this file.",
      "vars: {d2-config: {layout-engine: elk; pad: 20}}",
      "...@../tokens",
      "",
      "title: \"\($root): \(length) tài nguyên trên account trống\" {",
      "  shape: text",
      "  near: top-center",
      "  style: {font-size: 18; bold: true}",
      "}",
      "",
      "all: \"\" {",
      "  grid-rows: \(($np + $c - 1) / $c | floor)",
      "  grid-columns: \($c)",
      "  grid-gap: 40",
      "  style: {stroke: transparent; fill: transparent}",
      ($parts | to_entries[] | .key as $k | .value as $p | ($p.services | length) as $ns | ([$ns, 3] | min) as $sc
        | "  p\($k + 1): \"\($p.part) · \($p.n)\" {",
          "    class: workload",
          "    grid-rows: \(($ns + $sc - 1) / $sc | floor)",
          "    grid-columns: \($sc)",
          "    grid-gap: 24",
          ($p.services | to_entries[] | .key as $j | .value
            | if .icon then "    s\($j + 1): \"\(.name) · \(.n)\" {shape: image; icon: ../icons/\(.icon).svg; width: 48; height: 48; \($label)}"
              else "    s\($j + 1): \"\(.name) · \(.n)\" {class: sub}" end),
          "  }"),
      "}"'
}

# render DIR: SVG of every DIR/*.d2 in the light theme (0) and the dark one (200), as make diagrams renders them;
# DIR is a copy of docs/diagrams/inventory beside tokens.d2 and icons/, the container has no network.
render() {
  local dir=$1 f n theme tail
  for f in "$dir"/inventory/*.d2; do
    n=$(basename "$f" .d2)
    for theme in 0 200; do
      tail=; [ "$theme" = 0 ] || tail=-dark
      if ! docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp --network none --entrypoint d2 -v "$dir:/work" \
        -w /work "$D2_IMAGE" --theme "$theme" --scale 1 "inventory/$n.d2" "inventory/$n$tail.svg" >"$work/d2.log" 2>&1; then
        cat "$work/d2.log" >&2
        fail "d2 $diagrams/$n.d2"
      fi
    done
  done
}

# generate OUT: the page and the diagrams into OUT/docs/.
generate() {
  local out=$1 root fam note last=
  : >"$work/records.tsv"
  for root in "${ROOTS[@]}"; do
    echo "inventory $root" >&2
    plan "$root"
    records "$root" >>"$work/records.tsv"
  done
  mkdir -p "$out/docs/reference" "$out/$diagrams"
  {
    intro
    for root in "${ROOTS[@]}"; do
      fam=$(family "$root")
      # Assigned first: a fail inside the substitution of an argument would not stop the script.
      note=$(notes "$fam")
      printf '\n'
      if [ "$fam" = "$(slug "$root")" ]; then
        root_records "$root" | section "$root" '##' "$note"
      else
        [ "$fam" = "$last" ] || printf '## `%s`\n\n%s\n\n' "${root%/*}" "$note"
        root_records "$root" | section "$root" '###'
      fi
      last=$fam
      root_records "$root" | diagram "$root" >"$out/$diagrams/$(slug "$root").d2"
    done
  } >"$out/$page"
  cp "$repo/docs/diagrams/tokens.d2" "$out/docs/diagrams/"
  cp -R "$repo/docs/diagrams/icons" "$out/docs/diagrams/"
  render "$out/docs/diagrams"
  rm -rf "$out/docs/diagrams/tokens.d2" "$out/docs/diagrams/icons"
}

main() {
  local mode=${1:-} out f rc=0
  case $mode in write | check) ;; *) echo "usage: ci/inventory.sh write|check" >&2 && exit 2 ;; esac
  command -v jq >/dev/null || fail "jq is not installed"
  work=$(mktemp -d)
  locked=
  trap 'unlock; rm -rf "$work"' EXIT
  copy=$work/copy
  out=$work/out
  mkdir -p "$copy" "$out"
  copy_tree "$copy"
  check_roots
  generate "$out"
  if [ "$mode" = write ]; then
    mkdir -p "$repo/$diagrams" "$(dirname "$repo/$page")"
    rm -f "$repo/$diagrams"/*.d2 "$repo/$diagrams"/*.svg
    cp "$out/$page" "$repo/$page"
    cp "$out/$diagrams"/* "$repo/$diagrams/"
    echo "inventory: wrote $page and $diagrams/"
    return
  fi
  for f in "$page" $(cd "$out" && ls "$diagrams"/*); do
    cmp -s "$out/$f" "$repo/$f" || { echo "FAIL: $f is out of date or missing (run make inventory)" >&2 && rc=1; }
  done
  for f in "$repo/$diagrams"/*; do
    [ -e "$f" ] || continue
    [ -e "$out/$diagrams/$(basename "$f")" ] ||
      { echo "FAIL: $diagrams/$(basename "$f") is not generated by make inventory (remove it)" >&2 && rc=1; }
  done
  [ $rc = 0 ] && echo "inventory-check: $page and $diagrams/ match the plans"
  return $rc
}

main "$@"
