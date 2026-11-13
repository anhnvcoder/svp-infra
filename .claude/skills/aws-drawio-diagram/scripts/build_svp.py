#!/usr/bin/env python3
"""Generate `docs/diagrams/svp-aws.drawio` (+ PDF, PNG) from a Python spec — the drawio file is GENERATED, edit it here.

Four pages: stg, prd (one function, sizes read from the Terraform of this repository), org (organization, accounts, OUs,
policies, log and detection flows) and flows (release path to ECR, telemetry, upload to playback, request). Layout as in SKILL.md: rows = AZs, each holding its public, private and database subnet; columns = tiers (outside
→ global services of the account → public → private → database), the regional band below the VPC. Every coordinate is a multiple of 40 (major cell), icons 80px.

    python3 .claude/skills/aws-drawio-diagram/scripts/build_svp.py [--pdf] [--png DIR] [--docs]
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from drawio_lib import ACCOUNT, ANA, AZ, BAND, CLOUD, COMP, DB, INTEG, K8S, MUTED, NET, PRIVATE, PUBLIC, REGION, SEC, STO, STROKE, VPC, VPC_PURPLE, Page, bullets, export, write  # noqa: E402

ROOT = Path(__file__).resolve().parents[4]
OUT = ROOT / "docs/diagrams/svp-aws.drawio"


# ---------------------------------------------------------------- sizes, read from the Terraform (never typed here)
def tfvalue(raw: str):
    """A literal of a .tfvars line or a README cell: bool, number, quoted string, list of strings; anything else as is."""
    raw = raw.strip()
    if raw in ("true", "false"):
        return raw == "true"
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    if raw.startswith(("[", '"')):
        return json.loads(raw)
    return raw


def tfvars(path: Path) -> dict:
    out = {}
    for line in path.read_text(encoding="utf8").splitlines():
        m = re.match(r"^\s*(\w+)\s*=\s*(.+?)\s*$", line)
        if m and not line.lstrip().startswith("#"):
            out[m.group(1)] = tfvalue(m.group(2))
    return out


def var_default(path: Path, name: str):
    """`default` of `variable "name"` in a variables.tf."""
    block = re.search(rf'variable "{name}" \{{(.*?)\n\}}', path.read_text(encoding="utf8"), re.S)
    m = block and re.search(r"^\s*default\s*=\s*(.+)$", block.group(1), re.M)
    if not m:
        raise SystemExit(f"{path}: variable {name} has no default")
    return tfvalue(m.group(1))


def interface_services() -> list[str]:
    """`interface_endpoint_services` of modules/network/main.tf: the AWS APIs that get an interface endpoint."""
    text = (ROOT / "aws/modules/network/main.tf").read_text(encoding="utf8")
    block = re.search(r"interface_endpoint_services = \[(.*?)\]", text, re.S)
    if not block:
        raise SystemExit("aws/modules/network/main.tf: no interface_endpoint_services list")
    return re.findall(r'"([a-z0-9.-]+)"', block.group(1))


def cache_prefixes() -> list[str]:
    """Prefixes of the pull-through cache rules (`cache_rules` of modules/registry/main.tf)."""
    text = (ROOT / "aws/modules/registry/main.tf").read_text(encoding="utf8")
    block = re.search(r"cache_rules = \{(.*?)\n  \}", text, re.S)
    if not block:
        raise SystemExit("aws/modules/registry/main.tf: no cache_rules map")
    return re.findall(r'^\s*"?([a-z0-9-]+)"?\s*=\s*\{', block.group(1), re.M)


@dataclass(frozen=True)
class Env:
    name: str              # stg | prd
    region: str
    cidr: str
    az_count: int
    single_nat: bool
    capacity: str          # capacity type of Karpenter's NodePool: Spot | on-demand (NODEPOOL below)
    multi_az: bool         # RDS standby in a second AZ
    cache_nodes: int       # ElastiCache nodes: a primary, then replicas in the next AZs
    logs: tuple            # what writes to CloudWatch Logs; empty: no log group
    kms_eks: bool          # a customer managed KMS key encrypts the cluster's Secrets
    zone: str              # Route 53 zone as drawn: zone_name of the committed example, a placeholder domain
    media_free: bool       # media distribution on the flat-rate Free plan (no access log); every other distribution pays as you go
    dnssec: bool           # the zone is DNSSEC signed and has a query log (the same two root variables of aws/accounts/<env>)
    endpoint_azs: int      # AZs whose private subnet holds the ENIs of the interface endpoints (stg 1, prd az_count)

    @property
    def nat_rows(self) -> list[int]:
        return [0] if self.single_nat else list(range(self.az_count))


def zone_label(env: str) -> str:
    """`zone_name` of aws/accounts/<env>/<env>.auto.tfvars.example (the committed example, never the real file) as a drawn label."""
    zone = tfvars(ROOT / f"aws/accounts/{env}/{env}.auto.tfvars.example")["zone_name"]
    if not zone.endswith("svp.example"):
        raise SystemExit(f"aws/accounts/{env}: zone_name {zone!r} does not end in the example domain svp.example")
    return zone.removesuffix("svp.example") + "&lt;domain&gt;"


def zone_flag(env: str, name: str) -> bool:
    """`<name> = true|false` of the account-baseline call in aws/accounts/<env>/main.tf."""
    m = re.search(rf"^\s*{name}\s*=\s*(true|false)\s*$", (ROOT / f"aws/accounts/{env}/main.tf").read_text(encoding="utf8"), re.M)
    return bool(m) and m.group(1) == "true"


def envs() -> list[Env]:
    """Each env from its root: the committed aws/envs/<env>/<env>.tfvars, then the defaults of the root's variables.tf.
    One MSK broker per AZ (the roots set broker_count to az_count)."""
    cidr = var_default(ROOT / "aws/modules/network/variables.tf", "cidr")
    out = []
    for name in ("stg", "prd"):
        root = ROOT / f"aws/envs/{name}"
        given = tfvars(root / f"{name}.tfvars")
        v = lambda var: given[var] if var in given else var_default(root / "variables.tf", var)   # noqa: E731
        # The slow log of Valkey goes to a log group of the elasticache module in every env (no variable turns it off).
        # VPC flow logs and WAF logs go to the log archive account, not to a log group.
        logs = tuple(what for what, on in (("control plane", bool(v("control_plane_log_types"))),
                                           ("RDS", bool(v("rds_cloudwatch_logs_exports"))), ("MSK brokers", v("msk_broker_logs_enabled")),
                                           ("Valkey slow log", True))
                     if on)
        out.append(Env(name, v("region"), cidr, v("az_count"), v("single_nat_gateway"), NODEPOOL[name], v("rds_multi_az"),
                       v("valkey_node_count"), logs, v("eks_secrets_kms_encryption"), zone_label(name), v("media_flat_rate_free"),
                       zone_flag(name, "dnssec_enabled"), v("interface_endpoint_az_count")))
    return out


# Capacity type of the NodePool of Karpenter per env. It lives in svp-gitops (another repository, so it is typed here,
# not read): karpenter.sh/capacity-type of envs/<env>/svp-cluster.yaml. The system node group is on-demand in every env.
NODEPOOL = {"stg": "Spot", "prd": "on-demand"}

# Workloads drawn as Kubernetes icons, with their replicas per env. The numbers live in svp-gitops (another repository,
# so they are typed here, not read): base/services/<svc>.yaml, then envs/<env>/<svc>.yaml, over the svp-service chart's
# default of one replica. gateway and web run as Argo Rollouts (canary), drawn with the Deployment icon draw.io has.
SVP = [  # (name, stg, prd) — row A of the svp frame holds the first four, row B the rest
    ("web", "×2 · Rollout", "×2 · Rollout"),
    ("gateway", "×2–4 · Rollout, HPA", "×2–4 · Rollout, HPA"),
    ("user-service", "×1", "×2"),
    ("video-service", "×1", "×2"),
    ("engagement-service", "×1", "×2"),
    ("feed-service", "×2", "×2"),
    ("media-worker", "×1–2 · KEDA", "×1–2 · KEDA"),
]
# svp-data chart on EKS (Kafka, Valkey and Postgres managed): the ops Deployment and the two PostSync Jobs of Argo CD
SVP_DATA = [("deploy", "svp-ops ×1"), ("job", "kafka-init · Job"), ("job", "pg-bootstrap · Job")]
FRAMES = 7          # namespace frames of an env page, each marked with one ns icon


def expected(env: Env) -> dict[str, int]:
    """What the page of `env` must hold, by check_diagram.kind_counts() kind — derived from the sizes, not from the drawing."""
    n = env.az_count
    # three distributions with a web ACL each, one internal ALB, one ACM icon (viewer certificates in us-east-1,
    # the ALB's in the region)
    want = {"users": 1, "route_53": 1, "cloudfront": 3, "waf": 3, "internet_gateway": 1, "application_load_balancer": 1, "certificate_manager_2": 1, "eks": 1,
            "nat_gateway": len(env.nat_rows), "ec2": 2 * n, "instance2": 1, "rds": 2 if env.multi_az else 1, "managed_streaming_for_kafka": n,
            # endpoints: S3 gateway, guardduty-data interface, one icon per AZ holding the interface endpoints' ENIs;
            # s3: media, uploads and the three log archive buckets it writes (VPC flow, WAF, CloudFront access logs)
            "elasticache": env.cache_nodes, "endpoints": 2 + env.endpoint_azs, "s3": 5, "secrets_manager": 1, "key_management_service": 1,
            "elastic_block_store": n, "sns": 1, "sqs": 1, "eventbridge": 1, "systems_manager": 1,
            # account-level services that outlive the session: ECR, Inspector (scans the cache repositories), AMP, AMG,
            # the application log group (cloudwatch_2 below counts the alarm icon too), X-Ray
            "ecr": 1, "inspector": 1, "managed_service_for_prometheus": 1, "managed_service_for_grafana": 1, "xray": 1,
            "account": 2, "region": 1, "az": n, "subnet": 4 * n,
            # Kubernetes: a ns icon per frame; a workload icon per svp service, per svp-data workload, and Envoy's
            # proxy Deployment and its ClusterIP Service
            "k8s_ns": FRAMES, "k8s_deploy": len(SVP) + 1 + sum(k == "deploy" for k, _ in SVP_DATA),
            "k8s_job": sum(k == "job" for k, _ in SVP_DATA), "k8s_svc": 1}
    want["cloudwatch_2"] = 2 if env.logs else 1   # the alarms and service logs icon, and the application log group
    return want


def org_expected() -> dict[str, int]:
    """What the org page must hold, by check_diagram.kind_counts() kind: the five accounts, one icon per service the
    organization, the log archive and the security account run (see org_page)."""
    return {"account": 5, "organizations": 1, "single_sign_on": 1, "cloudtrail": 1, "eventbridge": 4, "s3": 6, "key_management_service": 1,
            "flow_logs": 2, "waf": 2, "cloudfront": 2, "config": 1, "guardduty": 1, "security_hub": 1, "access_analyzer": 1, "sns": 1, "users": 1,
            "inspector": 1, "managed_service_for_grafana": 2}


# ---------------------------------------------------------------- geometry of an env page
# Coordinates: the layout section of SKILL.md; why each part sits where it does: its content rules 0–13 (nesting Cloud
# → Account → Region → VPC → AZ → subnet, subnet tiers per AZ row, EBS outside the subnets, the ALB across the edge
# subnets of the first two AZ rows, the cluster box over each private box, database columns kept off replication lines).
CLOUD_X, ACCT_X, GLOBAL_X, REGION_X, IGW_X, VPC_X, AZ_X = 160, 200, 240, 400, 440, 560, 600
PUB_X, PUB_W, NAT_X = 640, 240, 680
EDGE_X, EDGE_W, ALB_X, EBS_X = 920, 240, 1000, 1200
PRIV_X, EKS_X, NODE_X, BASTION_X = 1320, 1560, 1600, 1360
COL, COL_W = (1720, 1960, 2200, 2440), 200
EKS_R, PRIV_R = 2680, 2720
DB_X, DB_R = 2760, 3480
LANE_MSK, LANE_CACHE = 2800, 2840                     # corridors of svp → MSK, svp → ElastiCache
RDS_X, CACHE_X, MSK_X = 3000, 3160, 3320      # clear of the database box's label
CLOUD_Y, ACCT_Y, REGION_Y, CP_Y, VPC_Y, SUB_H, AZ_H = 160, 200, 240, 320, 440, 400, 480
CP_X = 2440
AZ_R, VPC_R = DB_R + 40, DB_R + 80
REGION_R, ACCT_R, CLOUD_R = VPC_R + 40, VPC_R + 80, VPC_R + 120
PAGE_W = CLOUD_R + 40


def cidrs(env: Env):
    """Private, public, edge and database CIDR of each AZ, as modules/network computes them: the public subnets at the start
    of the last eighth of the VPC, the edge subnets in its back half."""
    net = ipaddress.ip_network(env.cidr)
    blocks = list(net.subnets(prefixlen_diff=3))
    public = list(blocks[7].subnets(prefixlen_diff=5))
    edge = list(blocks[7].subnets(prefixlen_diff=4))[8:]
    database = list(blocks[6].subnets(prefixlen_diff=3))
    return tuple([str(x[k]) for k in range(env.az_count)] for x in (blocks, public, edge, database))


def along(route, at) -> float:
    """label_pos (-1 source … 1 target) of the point `at` of an orthogonal route given as its points, both ends included."""
    segments = list(zip(route, route[1:]))
    lengths = [abs(x1 - x0) + abs(y1 - y0) for (x0, y0), (x1, y1) in segments]
    for i, ((x0, y0), (x1, y1)) in enumerate(segments):
        if min(x0, x1) <= at[0] <= max(x0, x1) and min(y0, y1) <= at[1] <= max(y0, y1):
            return round(2 * (sum(lengths[:i]) + abs(at[0] - x0) + abs(at[1] - y0)) / sum(lengths) - 1, 3)
    raise ValueError(f"{at} is not on the route {route}")


def frame(p: Page, title, x, y, w, h):
    """Namespace frame (a box, not an aws4 container): the ns icon in its top-left corner, the namespace name(s) beside it.
    No fill: a frame drawn across two AZs shows the subnet boxes and the AZ border it spans."""
    box = p.box("", x, y, w, h, "none", K8S)
    p.k8s("", "ns", x, y)
    p.text(f"<b>{title}</b>", x + 40, y, w - 40, 40)
    return box


def workload(p: Page, kind, label, x, y):
    """A Kubernetes icon with its name and replicas on its right, two lines in a 120-wide cell."""
    icon = p.k8s("", kind, x, y)
    p.text(label, x + 40, y, 120, 40)
    return icon


def env_page(env: Env) -> Page:
    n = env.az_count
    az = [VPC_Y + 40 + k * AZ_H for k in range(n)]      # top of each AZ row; the rows touch
    sub = [y + 40 for y in az]                            # top of its three subnet boxes
    a, b = sub[0], sub[1]
    alb_y = a + SUB_H                                     # bottom of the first edge box = top of the ALB
    bottom = az[-1] + AZ_H                                # bottom of the last AZ
    ep_y, vpc_b = bottom + 80, bottom + 200
    band_y = vpc_b + 40
    row = band_y + 40                                     # icon row of the band
    row2 = row + 200                                      # second icon row of the band: account-level observability, registry
    lane = band_y + 440                                   # users → uploads, below the band
    region_b = lane + 40
    acct_b = region_b + 40
    log_y = acct_b + 40                                   # the log archive account, under the env's own account
    log_icon, log_b = log_y + 80, log_y + 240
    cloud_b = log_b + 40
    priv, pub, edge, data = cidrs(env)

    p = Page(env.name, PAGE_W, cloud_b + 40)
    p.text(f"{env.name} — EKS cluster svp-{env.name}", 40, 0, 920, 40, size=17, bold=1)
    nat = "one NAT gateway, in the first AZ, for every private subnet" if env.single_nat else "one NAT gateway per AZ"
    p.text(f"{env.region} · {n} AZs, each with a public (NAT gateway only), an edge (the internal ALB only), a private and a "
           f"database subnet · {nat} · system node group on-demand and Karpenter's nodes ({env.capacity}), one icon each per AZ · "
           "API endpoint private only, reached through Systems Manager port forwarding to the SSM bastion · EBS volumes in the "
           "AZ of their pod's node · VPC flow logs, WAF logs and CloudFront access logs are written to S3 buckets of the "
           "svp-log-archive account", 40, 40, PAGE_W - 80, 40, color=MUTED)
    rds = ("RDS single-AZ" if not env.multi_az else "RDS Multi-AZ primary/standby")
    cache = ("ElastiCache for Valkey one node" if env.cache_nodes == 1
             else f"ElastiCache for Valkey primary and {env.cache_nodes - 1} replica(s), Multi-AZ, automatic failover")
    p.text(f"Database subnets, no route to the Internet: {rds} · Amazon MSK one broker per AZ, SASL/SCRAM-SHA-512 over TLS · "
           f"{cache} · AWS picks the AZs of RDS and ElastiCache (drawn from the first) · CloudWatch alarms of RDS, MSK and "
           "ElastiCache notify an SNS topic encrypted with a customer managed key, which emails the learner · KMS, Secrets "
           "Manager, CloudWatch, SNS, SQS, EventBridge regional", 40, 80, PAGE_W - 80, 40, color=MUTED)
    p.text("Kubernetes: a frame per namespace, an icon per workload with its replicas · the scheduler puts each pod on any "
           "node of any AZ, so the row of a frame or an icon says nothing about where its pods run (svp is drawn across "
           "the first two AZs to show it) · third-party tools as text · EKS add-ons (CoreDNS, kube-proxy, VPC CNI) not drawn; the "
           "GuardDuty runtime agent add-on reports through the guardduty-data interface endpoint",
           40, 120, PAGE_W - 80, 40, color=MUTED)

    # containers before icons (geometry rule 9)
    p.group("AWS Cloud", CLOUD_X, CLOUD_Y, CLOUD_R - CLOUD_X, cloud_b - CLOUD_Y, **CLOUD)
    p.group(f"AWS Account svp-{env.name}", ACCT_X, ACCT_Y, ACCT_R - ACCT_X, acct_b - ACCT_Y, **ACCOUNT)
    p.group(f"Region {env.region}", REGION_X, REGION_Y, REGION_R - REGION_X, region_b - REGION_Y, **REGION)
    p.group(f"VPC {env.cidr}", VPC_X, VPC_Y, VPC_R - VPC_X, vpc_b - VPC_Y, **VPC, cid="vpc")
    for k in range(n):
        p.group(f"AZ {env.region}{'abcdef'[k]}", AZ_X, az[k], AZ_R - AZ_X, AZ_H, **AZ)
        p.group(f"Public subnet {pub[k]}", PUB_X, sub[k], PUB_W, SUB_H, **PUBLIC, cid=f"pub{k}")
        p.group(f"Edge subnet {edge[k]}", EDGE_X, sub[k], EDGE_W, SUB_H, **{**PUBLIC, "grstroke": True}, cid=f"edge{k}")
        p.group(f"Private subnet {priv[k]}", PRIV_X, sub[k], PRIV_R - PRIV_X, SUB_H, **PRIVATE, cid=f"priv{k}")
        p.group(f"Database subnet {data[k]}", DB_X, sub[k], DB_R - DB_X, SUB_H, **PRIVATE, cid=f"db{k}")
    eks = p.group(f"EKS cluster svp-{env.name}", EKS_X, a, EKS_R - EKS_X, sub[-1] + SUB_H - a, gr="eks", stroke="#D05C17",
                  font="#D05C17", cid="eks")
    p.group("Regional services", VPC_X, band_y, VPC_R - VPC_X, 400, **BAND)
    p.group("AWS Account svp-log-archive · buckets written by this env", ACCT_X, log_y, ACCT_R - ACCT_X, log_b - log_y, **ACCOUNT)

    # namespace frames (boxes, not aws4 containers), every Kubernetes icon wholly inside one private box: first AZ rows
    # +160 and +280, second AZ rows +120 and +240; the fourth column of the second AZ stays free for svp → endpoint
    envoy = frame(p, "envoy-gateway-system", COL[0], a + 160, COL_W, 200)
    workload(p, "svc", "Service svp-envoy<br>ClusterIP", COL[0], a + 240)
    envoy_pods = workload(p, "deploy", "Envoy proxy<br>TargetGroupBinding", COL[0], a + 320)
    frame(p, "cert-manager", COL[1], a + 160, COL_W, 80)
    p.text("internal CA svp-ca<br>(Envoy's certificate)", COL[1], a + 200, COL_W, 40, align="center")
    frame(p, "argocd · argo-rollouts · kyverno · keda · external-secrets", COL[2], a + 160, 2 * COL_W + 40, 80)
    p.text("Argo CD, Argo Rollouts, Kyverno, KEDA, External Secrets", COL[2], a + 200, 2 * COL_W + 40, 40, align="center")

    svp_h = b + 120 - (a + 280)
    svp = frame(p, "svp", COL[1], a + 280, 3 * COL_W + 80, svp_h)
    for i, (name, stg, prd) in enumerate(SVP):
        x, y = (COL[1] + 40 + 160 * i, a + 320) if i < 4 else (COL[1] + 40 + 160 * (i - 4), b + 40)
        workload(p, "deploy", f"{name}<br>{stg if env.name == 'stg' else prd}", x, y)

    csi = frame(p, "kube-system", COL[0], b + 160, COL_W, 80)
    p.text("AWS Load Balancer Controller,<br>EBS CSI driver, Karpenter", COL[0], b + 200, COL_W, 40, align="center")
    # three one-line workloads, 40 apart: the frame has room for three rows of icons above the box's bottom margin
    frame(p, "svp-data", COL[1], b + 160, COL_W, 200)
    for i, (kind, label) in enumerate(SVP_DATA):
        workload(p, kind, label, COL[1], b + 200 + 40 * i)
    frame(p, "svp-obs", COL[2], b + 160, COL_W, 200)
    p.text(bullets("Prometheus agent ×2 → AMP", "OTel Collector", "ACK prometheusservice", "Grafana Operator", "Pyroscope, GlitchTip"),
           COL[2], b + 200, COL_W, 120)
    mid = COL[3] + 120                                    # x of svp → S3 endpoint (centre of the endpoint)

    # global services of the account, left of the Region; users outside the Cloud. Web and api distributions sit
    # beside the ALB rows, each under its web ACL; media's pair stays on the row of the band's bucket it reads
    users = p.flat("Users", "users", 40, alb_y, cid="users")
    r53_lines = [f"Route 53 · {env.zone}", "alias A/AAAA, CAA"] + (["DNSSEC, query log"] if env.dnssec else [])
    r53 = p.icon("<br>".join(r53_lines), "route_53", GLOBAL_X, a, NET, cid="r53")
    waf_web = p.icon(f"WAF web ACL<br>svp-{env.name}-web", "waf", GLOBAL_X, a + 200, SEC, cid="waf_web", label_top=True)
    cf_web = p.icon(f"CloudFront svp-{env.name}-web<br>{env.zone}", "cloudfront", GLOBAL_X, a + 360, NET, cid="cf_web")
    waf_api = p.icon(f"WAF web ACL<br>svp-{env.name}-api", "waf", GLOBAL_X, a + 560, SEC, cid="waf_api", label_top=True)
    cf_api = p.icon(f"CloudFront svp-{env.name}-api<br>api.{env.zone}", "cloudfront", GLOBAL_X, a + 720, NET, cid="cf_api")
    waf = p.icon(f"WAF web ACL<br>svp-{env.name}-media", "waf", GLOBAL_X, row - 200, SEC, cid="waf", label_top=True)
    cf = p.icon(f"CloudFront svp-{env.name}-media<br>media.{env.zone}", "cloudfront", GLOBAL_X, row, NET, cid="cf")
    igw = p.flat("Internet gateway", "internet_gateway", IGW_X, a + 40, VPC_PURPLE, cid="igw")
    cp = p.icon("EKS control plane · AWS managed", "eks", CP_X, CP_Y, COMP, cid="cp", label_top=True)
    alb = p.icon(f"ALB svp-{env.name}-edge<br>internal, HTTPS 443", "application_load_balancer", ALB_X, alb_y, NET, cid="alb", label_top=True)
    p.text("Web and API: viewer → CloudFront (web ACL, ACM certificate in us-east-1) → CloudFront VPC origin → internal ALB in the "
           "edge subnets, which only CloudFront may reach (security group on the CloudFront origin-facing prefix list); the ALB "
           "targets Envoy's pods directly (target group svp-" + env.name + "-envoy, filled by the TargetGroupBinding), Envoy "
           "routes by Host to web and gateway · Media: CloudFront → S3 media through origin access control, " +
           ("flat-rate Free plan, no access log" if env.media_free else "pay-as-you-go") + " · Route 53 aliases to the three "
           "distributions · access logs of " + ("web and API (media has none)" if env.media_free else "the three distributions") +
           " and logs of the three web ACLs go to the log archive account", REGION_X + 240, 280, 1640, 120, color=MUTED,
           valign="top")
    ep = p.flat("S3 gateway endpoint", "endpoints", mid - 40, ep_y, VPC_PURPLE, cid="s3ep")
    gd_ep = p.flat("GuardDuty interface endpoint<br>guardduty-data, 443 from the VPC", "endpoints", mid + 240, ep_y, VPC_PURPLE, cid="gdep")
    waf_logs = p.icon("S3 aws-waf-logs-svp<br>logs of the three web ACLs, us-east-1", "s3", GLOBAL_X, log_icon, STO, cid="waflogs")
    cf_logs = p.icon("S3 svp-cloudfront<br>CloudFront access logs, us-east-1", "s3", GLOBAL_X + 240, log_icon, STO, cid="cflogs")
    p.text("SSE-KMS with alias/svp-log-archive · blocked from public access · written by service principals of the "
           "organization (aws:SourceOrgID)", GLOBAL_X + 480, log_icon, 1040, 80, color=MUTED)
    flow_logs = p.icon("S3 svp-flowlogs<br>VPC flow logs", "s3", ACCT_R - 120, log_icon, STO, cid="flowlogs")

    nats = {k: p.flat("NAT gateway", "nat_gateway", NAT_X, sub[k] + 40, VPC_PURPLE, cid=f"nat{k}") for k in env.nat_rows}
    nodes = [p.icon("System node group<br>on-demand", "ec2", NODE_X, sub[k] + 40, COMP, cid=f"node{k}") for k in range(n)]
    # below the system node, clear of the kube-system → EBS line that crosses the node column of the second AZ at +200
    karpenter = [p.icon(f"Karpenter node<br>{env.capacity}", "ec2", NODE_X, sub[k] + 240, COMP, cid=f"karp{k}") for k in range(n)]
    # private subnet of the first AZ, left of the cluster box, below the node → NAT line
    bastion = p.flat("SSM bastion · t4g.nano", "instance2", BASTION_X, a + 160, COMP[0], cid="bastion")
    ebs = [p.icon("EBS gp3 · PVCs", "elastic_block_store", EBS_X, sub[k] + 160, STO, cid=f"ebs{k}") for k in range(n)]
    # one icon per AZ that holds the ENIs of every interface endpoint (list in modules/network), left of the cluster
    services = interface_services()
    eni = [p.flat(f"Interface endpoints<br>{len(services)} AWS APIs, ENIs", "endpoints", BASTION_X, sub[k] + 280, VPC_PURPLE, cid=f"eni{k}")
           for k in range(env.endpoint_azs)]

    # database tier: RDS, ElastiCache nodes (primary first), one MSK broker per AZ
    db = p.icon("RDS PostgreSQL" + (" primary" if env.multi_az else ""), "rds", RDS_X, a + 280, DB, cid="rds0")
    standby = p.icon("RDS standby", "rds", RDS_X, b + 280, DB, cid="rds1") if env.multi_az else None
    caches = [p.icon("ElastiCache Valkey" + ("" if env.cache_nodes == 1 else " primary" if k == 0 else " replica"),
                     "elasticache", CACHE_X, sub[k] + 160, DB, cid=f"cache{k}") for k in range(env.cache_nodes)]
    brokers = [p.icon("MSK broker", "managed_streaming_for_kafka", MSK_X, sub[k] + 40, ANA, cid=f"msk{k}") for k in range(n)]

    media = p.icon("S3 media", "s3", 600, row, STO, cid="media")
    # entered from below by the browser
    uploads = p.icon("S3 uploads<br>GuardDuty malware scan", "s3", 760, row, STO, cid="uploads", label_top=True)
    p.icon(f"Secrets Manager<br>RDS master, svp/{env.name}/*,<br>AmazonMSK_*, ecr-pullthroughcache/*", "secrets_manager", 1000, row, SEC,
           cid="sm")
    keys = "Terraform state, RDS, MSK,<br>SNS of the alarms, ECR,<br>observability" + ("<br>EKS Secrets" if env.kms_eks else "")
    p.icon(f"KMS keys, customer managed<br>{keys}", "key_management_service", 1280, row, SEC, cid="kms")
    cw = None
    if env.logs:
        lines = ["CloudWatch: alarms, Logs", ", ".join(env.logs[:2]), ", ".join(env.logs[2:])]
        cw = p.icon("<br>".join(x for x in lines if x), "cloudwatch_2", 1560, row, SEC, cid="cw")
    sns = p.icon(f"SNS svp-{env.name}-alarms<br>email to the learner", "sns", 1840, row, INTEG, cid="sns")
    events = p.icon("EventBridge rules<br>Spot interruption, rebalance,<br>instance state", "eventbridge", 2120, row, INTEG,
                    cid="events")
    queue = p.icon(f"SQS svp-{env.name}-karpenter<br>read by Karpenter", "sqs", 2400, row, INTEG, cid="sqs")
    p.icon("Systems Manager<br>port forwarding to the bastion", "systems_manager", 2680, row, SEC, cid="ssm")

    # account-level services of the session's data: they live in aws/accounts/<env>, so destroy leaves them
    ecr = p.icon(f"ECR svp-{env.name}<br>svp-backend/*, svp-frontend/web<br>cache: {', '.join(cache_prefixes())}", "ecr",
                 640, row2, COMP, cid="ecr")
    scan = p.icon("Inspector<br>enhanced scan of the cache repositories", "inspector", 920, row2, SEC, cid="inspector")
    amp = p.icon(f"AMP workspace svp-{env.name}<br>metrics, rules, alerts", "managed_service_for_prometheus", 1200, row2, SEC, cid="amp")
    amg = p.icon(f"AMG svp-{env.name}<br>IAM Identity Center sign-in", "managed_service_for_grafana", 1480, row2, SEC, cid="amg")
    app_logs = p.icon(f"CloudWatch Logs<br>/svp/{env.name}/otel, aws/spans", "cloudwatch_2", 1760, row2, SEC, cid="applogs")
    xray = p.icon("X-Ray<br>Transaction Search", "xray", 2040, row2, SEC, cid="xray")
    p.text(bullets(
        f"ECR, AMP, AMG, the application log group and the X-Ray settings are in the root of the account, so they outlive the "
        f"session; keys alias/svp-{env.name}-ecr and alias/svp-{env.name}-observability",
        "Collector and Prometheus agent write to AMP, CloudWatch Logs and X-Ray; nodes pull images from ECR, third-party images "
        "through its pull-through cache",
        f"Interface endpoints: private DNS, 443 from the VPC, ENIs in the private subnets of the first {env.endpoint_azs} AZ(s); "
        "GitHub, Sigstore, Telegram, upstream registries, the Pricing API and AMG still go through NAT"),
        2320, row2, 1160, 120, valign="top")
    p.icon(f"ACM · ALB certificate, {env.region}<br>viewer certificates in us-east-1", "certificate_manager_2", 2960, row, SEC, cid="acm")

    # request path: DNS, CloudFront, VPC origin, ALB, Envoy, services, databases. The origin edges and ALB → Envoy run
    # 20 above and 20 below the shared AZ border (bottom margin of the first AZ, top margin of the second), never on
    # the dashed line itself (the controllers' edge runs 20 below it, left of the cluster).
    p.edge(users, r53, label="DNS", exit_=(0.5, 0), entry=(0, 0.5), points=[(80, a + 40)])
    p.edge(users, cf_web, STROKE["net"], exit_=(1, 0.5), entry=(0, 0.5), points=[(180, alb_y + 40), (180, a + 400)])
    p.edge(users, cf_api, STROKE["net"], exit_=(1, 0.5), entry=(0, 0.5), points=[(180, alb_y + 40), (180, a + 760)])
    route = [(GLOBAL_X + 80, a + 400), (REGION_X + 120, a + 400), (REGION_X + 120, alb_y + 20), (ALB_X, alb_y + 20)]
    p.edge(cf_web, alb, STROKE["net"], label="VPC origin", exit_=(1, 0.5), entry=(0, 0.25), points=route[1:3],
           label_pos=along(route, ((VPC_X + ALB_X) // 2 - 100, alb_y + 20)))
    p.edge(cf_api, alb, STROKE["net"], exit_=(1, 0.5), entry=(0, 0.75),
           points=[(REGION_X + 120, a + 760), (REGION_X + 120, alb_y + 60)])
    p.edge(waf_web, cf_web, STROKE["sec"], dashed=True, arrow=False, exit_=(0.5, 1), entry=(0.5, 0))
    p.edge(waf_api, cf_api, STROKE["sec"], dashed=True, arrow=False, exit_=(0.5, 1), entry=(0.5, 0))
    p.edge(alb, envoy_pods, STROKE["net"], label="HTTPS 10443", exit_=(1, 0.25), entry=(0.5, 1), points=[(COL[0] + 20, alb_y + 20)])
    p.edge(envoy, svp, STROKE["net"], exit_=(1, 0.9), entry=(0, 60 / svp_h))
    # svp → RDS straight on the RDS row; svp → ElastiCache and svp → MSK leave svp's right side above it and climb
    # the two corridors, MSK (the higher row) in the left one, so no two routes cross
    svp_r = COL[1] + 3 * COL_W + 80
    p.edge(svp, db, STROKE["db"], label="5432 · TLS", exit_=(1, 40 / svp_h), entry=(0, 0.5),
           label_pos=along([(svp_r, a + 320), (RDS_X, a + 320)], (RDS_X - 40, a + 320)))
    route = [(svp_r, a + 300), (LANE_CACHE, a + 300), (LANE_CACHE, a + 200), (CACHE_X, a + 200)]
    p.edge(svp, caches[0], STROKE["db"], label="6379 · TLS", exit_=(1, 20 / svp_h), entry=(0, 0.5), points=route[1:3],
           label_pos=along(route, ((LANE_CACHE + CACHE_X) // 2, a + 200)))
    route = [(svp_r, a + 290), (LANE_MSK, a + 290), (LANE_MSK, a + 80), (MSK_X, a + 80)]
    p.edge(svp, brokers[0], STROKE["db"], label="9096 · SASL/SCRAM-SHA-512, TLS", exit_=(1, 10 / svp_h), entry=(0, 0.5),
           points=route[1:3], label_pos=along(route, ((LANE_MSK + MSK_X) // 2, a + 80)))
    if standby:
        p.edge(db, standby, STROKE["db"], dashed=True, exit_=(0.5, 1), entry=(0.5, 0))
    for k in range(1, env.cache_nodes):
        p.edge(caches[0], caches[k], STROKE["db"], dashed=True, exit_=(0.5, 1), entry=(0.5, 0))
    p.edge(cp, eks, COMP[0], exit_=(0.5, 1), entry=((CP_X + 40 - EKS_X) / (EKS_R - EKS_X), 0))
    # the bastion reaches the private endpoint of the API, whose network interfaces sit in the private subnets
    # (not drawn)
    p.edge(bastion, eks, COMP[0], label="443 · API", exit_=(1, 0.5), entry=(0, (a + 200 - a) / (sub[-1] + SUB_H - a)))

    # egress: nodes → NAT of their AZ (stg: only the first AZ has one), the first NAT → IGW
    for k in env.nat_rows:
        p.edge(nodes[k], nats[k], STROKE["vpc"], dashed=True)
    p.edge(nats[0], igw, STROKE["vpc"], dashed=True, exit_=(0, 0.5), entry=(1, 0.5))

    # controllers that create AWS resources. kube-system → ALB rises right of the node column into the top margin of
    # the second AZ, then left into the ALB's side: from below it would cross every node → NAT line of a NAT per AZ.
    # Its label sits left of the cluster: the middle of the route would fall on the cluster's border.
    p.edge(csi, alb, STROKE["net"], dashed=True, label="registers targets", exit_=(0.25, 0), entry=(1, 0.75),
           points=[(COL[0] + 50, alb_y + 60)], label_pos=0.33)
    p.edge(csi, ebs[1], STROKE["sto"], dashed=True, label="volumes", exit_=(0, 0.5), entry=(1, 0.5))
    p.edge(csi, karpenter[1], COMP[0], dashed=True, exit_=(0.25, 1), entry=(1, 0.5), points=[(COL[0] + 50, b + 280)])

    # the agent on the nodes reaches GuardDuty through its interface endpoint, down the right of the cluster
    p.edge(eks, gd_ep, STROKE["sec"], dashed=True, label="runtime events", exit_=((mid + 80 - EKS_X) / (EKS_R - EKS_X), 1), entry=(0, 0.5))

    # S3: pods through the gateway endpoint (no NAT), the browser straight to uploads, CloudFront (behind its web ACL)
    # reads media
    p.edge(svp, ep, STROKE["sto"], exit_=((mid - COL[1]) / (3 * COL_W + 80), 1), entry=(0.5, 0))
    # into the side of media, down the gap between the two buckets: from the top it would cross the band's label
    p.edge(ep, media, STROKE["sto"], exit_=(0, 0.25), entry=(1, 0.5), points=[(720, ep_y + 20), (720, row + 40)])
    p.edge(ep, uploads, STROKE["sto"], exit_=(0, 0.75), entry=(1, 0.5), points=[(880, ep_y + 60), (880, row + 40)])
    # label on the lane below the band (x 480, inside the Region left of the band): the middle of the route is on the
    # page's left edge
    route = [(60, alb_y + 80), (60, lane), (800, lane), (800, row + 80)]
    p.edge(users, uploads, STROKE["sto"], label="POST presigned form", exit_=(0.25, 1), entry=(0.5, 1), points=route[1:3],
           label_pos=along(route, (480, lane)))
    p.edge(users, cf, STROKE["net"], label="GET HLS", exit_=(0.75, 1), entry=(0, 0.5), points=[(100, row + 40)])
    p.edge(waf, cf, STROKE["sec"], dashed=True, arrow=False, exit_=(0.5, 1), entry=(0.5, 0))

    # logs to the log archive account: the three web ACLs down one corridor between the global column and the Region
    # (left of it run the users' edges), the VPC down the one right of the Region
    waf_x = REGION_X - 40
    route = [(GLOBAL_X + 80, a + 240), (waf_x, a + 240), (waf_x, log_icon + 40), (GLOBAL_X + 80, log_icon + 40)]
    p.edge(waf_web, waf_logs, STROKE["sec"], dashed=True, label="logs", exit_=(1, 0.5), entry=(1, 0.5), points=route[1:3],
           label_pos=along(route, (waf_x, log_y - 20)))
    for acl, y in ((waf_api, a + 600), (waf, row - 160)):
        p.edge(acl, waf_logs, STROKE["sec"], dashed=True, exit_=(1, 0.5), entry=(1, 0.5),
               points=[(waf_x, y), (waf_x, log_icon + 40)])
    lane_x, out_y = VPC_R + 60, bottom + 100
    p.edge("vpc", flow_logs, STROKE["sto"], dashed=True, label="flow logs", exit_=(1, (out_y - VPC_Y) / (vpc_b - VPC_Y)), entry=(1, 0.5),
           points=[(lane_x, out_y), (lane_x, log_icon + 40)], label_pos=0.5)
    p.edge(cf, media, STROKE["sto"], label="OAC")

    # alarms and interruptions, inside the band
    if cw:
        p.edge(cw, sns, STROKE["integ"], label="alarm, OK")
    p.edge(events, queue, STROKE["integ"])
    p.edge(scan, ecr, STROKE["sec"], dashed=True, label="scan", exit_=(0, 0.5), entry=(1, 0.5))
    p.edge(amg, amp, STROKE["sec"], label="PromQL", exit_=(0, 0.5), entry=(1, 0.5))
    p.edge(amg, app_logs, STROKE["sec"], label="Logs Insights", exit_=(1, 0.5), entry=(0, 0.5))
    p.edge(xray, app_logs, STROKE["sec"], label="spans", exit_=(0, 0.5), entry=(1, 0.5))
    # the nodes and pods reach the AWS APIs through the endpoint of their AZ (the first AZ drawn)
    p.edge(eks, eni[0], STROKE["vpc"], dashed=True, label="443", exit_=(0, 320 / (sub[-1] + SUB_H - a)), entry=(1, 0.5))
    return p


# ---------------------------------------------------------------- org page: organization, accounts, policies, flows
ORG = dict(gr="group_security_group", stroke="#232F3E", grstroke=True)       # the organization's root
# OU: solid, since a dashed box without fill reads as an AZ
OU = dict(gr="group_security_group", stroke="#5A6C86", grstroke=True)
POLICY_TYPE = {"SERVICE_CONTROL_POLICY": "SCP", "RESOURCE_CONTROL_POLICY": "RCP", "DECLARATIVE_POLICY_EC2": "Declarative policy",
               "TAG_POLICY": "Tag policy"}


def org_policies() -> list[tuple[str, str, str]]:
    """(name, type, target) of each policy of modules/org-policies/main.tf, read from the `policies` map: the name is the
    key with the `svp-` prefix the module adds, the target `root_id` or `prod_ou_id`."""
    text = (ROOT / "aws/modules/org-policies/main.tf").read_text(encoding="utf8")
    out = []
    for m in re.finditer(r'^    "([a-z0-9-]+)" = \{\n(.*?)^    \}$', text, re.S | re.M):
        t = re.search(r'^\s*type\s*=\s*"(\w+)"', m.group(2), re.M)
        target = re.search(r"^\s*target_id\s*=\s*var\.(\w+)", m.group(2), re.M)
        if t and target:
            out.append((f"svp-{m.group(1)}", t.group(1), target.group(1)))
    if not out:
        raise SystemExit("aws/modules/org-policies/main.tf: no policy found in the policies map")
    return out


def org_page() -> Page:
    pol = org_policies()
    at = lambda target: [f"{POLICY_TYPE[t]} <b>{n}</b>" for n, t, tg in pol if tg == target]   # noqa: E731
    on_root, on_prod = at("root_id"), at("prod_ou_id")
    scp = [x for x in on_root if x.startswith("SCP")]
    rest = [x for x in on_root if not x.startswith("SCP")]

    p = Page("org", 2840, 2600)
    p.text("org — organization, accounts and security flows", 40, 0, 920, 40, size=17, bold=1)
    p.text("The management account holds the organization, IAM Identity Center and the organization trail · accounts in OUs as in the "
           "AWS Security Reference Architecture: Security (log archive, security tooling) and Workloads (Prod, NonProd) · every "
           "account also runs the baseline (S3 Block Public Access, EBS default encryption, Config recorder to svp-config)",
           40, 40, 2760, 40, color=MUTED)
    p.text("Green: logs to the log archive account · red: detection and events to the security account, then SNS and email · "
           "policies on the root reach every member account (SCP, RCP) or every account (declarative, tag)", 40, 80, 2760, 40, color=MUTED)

    p.group("AWS Organization · root", 40, 160, 2760, 2360, **ORG)
    p.box("<b>On the root: service control policies</b>" + bullets(*scp), 80, 240, 840, 200, "#F7F7F7", MUTED, valign="top")
    p.box("<b>On the root: resource control, declarative, tag</b>" + bullets(*rest), 960, 240, 840, 200, "#F7F7F7", MUTED, valign="top")
    p.box("<b>Organization features</b>" + bullets(
        "Centralized root access: member accounts hold no root credentials",
        "Delegated administrator svp-security: GuardDuty, Security Hub, Config, IAM Access Analyzer, Inspector (ECR scanning of every member account)",
        "Baseline roots apply from the management account through OrganizationAccountAccessRole"),
        1840, 240, 880, 200, "#F7F7F7", MUTED, valign="top")

    # management account (left), Security OU (middle), Workloads OU (right); rows of the log archive buckets at BUCKET
    p.group("Management account", 80, 560, 600, 1040, **ACCOUNT)
    p.group("OU Security", 760, 560, 880, 1560, **OU)
    p.group("svp-log-archive", 800, 640, 800, 880, **ACCOUNT)
    p.group("svp-security · delegated administrator", 800, 1560, 800, 520, **ACCOUNT)
    p.group("OU Workloads", 2000, 560, 720, 1920, **OU)
    p.group("OU Prod", 2040, 600, 640, 880, **OU)
    p.group("svp-prd", 2080, 680, 560, 720, **ACCOUNT)
    p.group("OU NonProd", 2040, 1520, 640, 920, **OU)
    p.group("svp-stg", 2080, 1600, 560, 720, **ACCOUNT)
    p.text("<b>On OU Prod:</b> " + ", ".join(on_prod), 2080, 1400, 560, 40)

    # management account
    p.icon("AWS Organizations<br>root, OUs, member accounts", "organizations", 320, 720, SEC, cid="orgs")
    p.icon("IAM Identity Center<br>SvpAdmin, SvpReadOnly, SvpLogReader<br>platform groups svp-platform-admins, -viewers", "single_sign_on",
           320, 880, SEC, cid="idc")
    trail = p.icon("CloudTrail organization trail<br>management events, S3 data events of prd", "cloudtrail", 320, 1040, SEC, cid="trail")
    m_fwd = p.icon("EventBridge svp-security-* rules<br>forwarder role", "eventbridge", 320, 1360, INTEG, cid="mfwd", label_top=True)

    # log archive: one bucket per kind of log, in a column the sources reach from both sides
    b = {"cloudtrail": 720, "config": 880, "flowlogs": 1040, "waf": 1200, "guardduty": 1360, "cloudfront": 1360}
    buckets = {
        "cloudtrail": p.icon("S3 svp-cloudtrail<br>organization trail, Object Lock", "s3", 1000, b["cloudtrail"], STO, cid="b_trail"),
        "config": p.icon("S3 svp-config<br>recorder of every account", "s3", 1000, b["config"], STO, cid="b_config"),
        "flowlogs": p.icon("S3 svp-flowlogs<br>VPC flow logs", "s3", 1000, b["flowlogs"], STO, cid="b_flow"),
        "waf": p.icon("S3 aws-waf-logs-svp<br>WAF logs, us-east-1", "s3", 1000, b["waf"], STO, cid="b_waf"),
        "guardduty": p.icon("S3 svp-guardduty<br>finding export", "s3", 1000, b["guardduty"], STO, cid="b_gd", label_top=True),
        "cloudfront": p.icon("S3 svp-cloudfront<br>CloudFront access logs, us-east-1", "s3", 1320, b["cloudfront"], STO, cid="b_cf"),
    }
    p.icon("KMS alias/svp-log-archive<br>a key in each bucket region", "key_management_service", 1320, b["config"], SEC, cid="kms")

    # security account
    p.icon("Config aggregator<br>whole organization", "config", 840, 1640, SEC, cid="agg")
    gd = p.icon("GuardDuty<br>organization, 2 regions", "guardduty", 1000, 1640, SEC, cid="gd")
    hub = p.icon("Security Hub<br>FSBP, CIS v5", "security_hub", 1160, 1640, SEC, cid="hub", label_top=True)
    p.icon("IAM Access Analyzer<br>organization", "access_analyzer", 1320, 1640, SEC, cid="aa")
    insp = p.icon("Amazon Inspector<br>delegated admin, ECR only", "inspector", 1480, 1640, SEC, cid="insp")
    bus = p.icon("EventBridge bus<br>svp-security-events", "eventbridge", 1320, 1880, INTEG, cid="bus", label_top=True)
    sns = p.icon("SNS svp-security-alarms", "sns", 1480, 1880, INTEG, cid="sns")
    learner = p.flat("Learner<br>email", "users", 1680, 1880, cid="learner")

    # workload accounts: the log sources of an env and its event forwarder
    sources = {}
    for env, top in (("prd", 760), ("stg", 1680)):
        sources[env] = (
            p.flat("VPC flow logs", "flow_logs", 2160, top, VPC_PURPLE, cid=f"{env}_flow"),
            p.icon("WAF web ACL logging<br>aws-waf-logs-svp", "waf", 2160, top + 160, SEC, cid=f"{env}_waf"),
            p.icon("CloudFront standard logging<br>svp-cloudfront-" + env, "cloudfront", 2160, top + 320, NET, cid=f"{env}_cf"),
            p.icon("EventBridge svp-security-* rules<br>forwarder role", "eventbridge", 2160, top + 480, INTEG, cid=f"{env}_fwd", label_top=True))
        p.icon(f"AMG svp-{env}<br>ADMIN svp-platform-admins<br>VIEWER svp-platform-viewers", "managed_service_for_grafana", 2440, top, SEC,
               cid=f"{env}_amg")

    green, integ, sec = STROKE["sto"], STROKE["integ"], STROKE["sec"]
    # logs: left lane x=720 from the management account, lanes right of the Security OU from the workload accounts
    p.edge(trail, buckets["cloudtrail"], green, exit_=(1, 0.5), entry=(0, 0.5), points=[(720, 1080), (720, b["cloudtrail"] + 40)])
    p.edge(gd, buckets["guardduty"], green, exit_=(0.5, 0), entry=(0.5, 1))
    lanes = {("prd", "flow"): 1840, ("prd", "waf"): 1860, ("stg", "waf"): 1880, ("stg", "flow"): 1900,
             ("prd", "cf"): 1960, ("stg", "cf"): 1980}
    ys = {"prd": 760, "stg": 1680}
    for env in ("prd", "stg"):
        flow, waf, cf, _ = sources[env]
        for src, kind, dy in ((flow, "flow", 0), (waf, "waf", 160), (cf, "cf", 320)):
            lane = lanes[(env, kind)]
            bucket = {"flow": "flowlogs", "waf": "waf", "cf": "cloudfront"}[kind]
            p.edge(src, buckets[bucket], green, exit_=(0, 0.5), entry=(1, 0.5),
                   points=[(lane, ys[env] + dy + 40), (lane, b[bucket] + 40)])
    # detection: GuardDuty and Access Analyzer findings into Security Hub, Security Hub and every account's rules
    # to the bus
    p.edge(gd, hub, sec, label="findings")
    p.edge("aa", hub, sec)
    # Inspector findings reach Security Hub below the row, up into the bottom of the hub (its label is on top)
    p.edge(insp, hub, sec, exit_=(0.5, 1), entry=(0.75, 1), points=[(1520, 1760), (1220, 1760)])
    p.edge(hub, bus, integ, exit_=(0.5, 1), entry=(0, 0.5))
    p.edge(m_fwd, bus, integ, exit_=(1, 0.5), entry=(0.5, 1), points=[(720, 1400), (720, 2040), (1360, 2040)])
    for env, lane in (("prd", 1920), ("stg", 1940)):
        fwd = sources[env][3]
        p.edge(fwd, bus, integ, exit_=(0, 0.5), entry=(0.5, 1),
               points=[(lane, ys[env] + 520), (lane, 2040), (1360, 2040)])
    p.edge(bus, sns, integ)
    p.edge(sns, learner, integ, label="email")
    return p


def flows(region: str) -> Page:
    u, r, t = 880, 1240, 1840              # tops of the upload, request and telemetry blocks
    p = Page("flows", 1880, t + 1120)
    p.text("Flows — image release, upload to playback, request to the web and API, telemetry", 40, 0, 1400, 40, size=17, bold=1)
    p.text("Release: commit → signed image → ECR (same digest) → svp-gitops → Argo CD", 40, 120, 880, 40, size=13, bold=1)
    p.text("Upload to playback", 40, u, 880, 40, size=13, bold=1)
    # Release: GHCR stays the build target; CI copies the same digest and its signatures to the ECR of each account
    # with a role assumed through GitHub's OIDC token, so no stored key exists.
    p.group(f"AWS Cloud · {region}", 920, 120, 920, 720, **CLOUD)
    ecr_regs = (("stg", 160, "svp-ci-ecr-release-backend, -frontend<br>OIDC, branch main"),
                ("prd", 400, "svp-ci-ecr-promote<br>OIDC, environment promote-prd"))
    for env, y, _ in ecr_regs:
        p.group(f"AWS Account svp-{env}", 960, y, 840, 200, **ACCOUNT)
    p.group("EKS cluster svp-&lt;env&gt;", 960, 640, 840, 160, gr="eks", stroke="#D05C17", font="#D05C17")
    gh = p.box("<b>GitHub Actions · svp-backend, svp-frontend</b><br>images.yml: build, scan, sign, attest, then ecr-copy", 40, 280,
               320, 80, "#F7F7F7", MUTED, align="center")
    ghcr = p.box("<b>GHCR</b><br>images by digest · cosign, vuln, SLSA provenance", 480, 280, 320, 80, "#F7F7F7", MUTED, align="center")
    ecr = {}
    for env, y, role in ecr_regs:
        ecr[env] = p.icon(f"ECR svp-{env}<br>svp-backend/*<br>svp-frontend/web", "ecr", 1000, y + 40, COMP, cid=f"ecr_{env}")
        p.text(f"<b>OIDC role</b><br>{role}", 1200, y + 40, 560, 80, color=MUTED, align="left")
    git = p.box("<b>GitHub · svp-gitops</b><br>envs/&lt;env&gt;/images, charts.yaml · PR by the bot", 40, 480, 320, 80, "#F7F7F7", MUTED, align="center")
    argo = frame(p, "argocd", 1000, 680, 320, 80)
    p.text("Argo CD: syncs values, charts", 1000, 720, 320, 40, align="center")
    frame(p, "kyverno", 1400, 680, 360, 80)
    p.text("svp-registry-mirror, signature check at ECR", 1400, 720, 360, 40, align="center")
    p.text("Nodes pull by digest from the ECR of their account through the ecr.api, ecr.dkr interface endpoints and the S3 gateway "
           "endpoint; third-party images come through the pull-through cache", 1000, 760, 760, 40, color=MUTED)
    p.edge(gh, ghcr, label="push, sign")
    p.edge(ghcr, ecr["stg"], STROKE["comp"], label="copy", exit_=(1, 0.5), entry=(0, 0.5), points=[(880, 320), (880, 240)],
           label_pos=0.3)
    p.edge(ghcr, ecr["prd"], STROKE["comp"], label="promote-prd", exit_=(1, 0.5), entry=(0, 0.5), points=[(880, 320), (880, 480)],
           label_pos=0.3)
    p.edge(gh, git, label="promote PR, once ECR has the digest")
    # no label: the Cloud border crosses its middle; the argocd frame says what it syncs
    p.edge(git, argo, exit_=(1, 0.5), entry=(0, 0.5), points=[(900, 520), (900, 720)])

    # Cloud: the buckets (regional) and the cluster; CloudFront is global, outside it (content rule 3). Every edge label
    # lies clear of the borders its edge crosses.
    p.group(f"AWS Cloud · {region}", 160, u + 40, 1160, 280, **CLOUD)
    p.group("EKS cluster svp-&lt;env&gt;", 720, u + 80, 200, 200, gr="eks", stroke="#D05C17", font="#D05C17")
    creator = p.flat("Creator", "users", 40, u + 120, cid="creator")
    up = p.icon("S3 uploads", "s3", 320, u + 120, STO, cid="up")
    worker = p.k8s("media-worker<br>Deployment · KEDA", "deploy", 760, u + 120, size=80, cid="worker")
    media = p.icon("S3 media", "s3", 1200, u + 120, STO, cid="med")
    cf = p.icon("CloudFront<br>svp-&lt;env&gt;-media", "cloudfront", 1480, u + 120, NET, cid="cdn")
    viewer = p.flat("Viewer", "users", 1720, u + 120, cid="viewer")
    p.edge(creator, up, STROKE["sto"], label="POST presigned")
    p.edge(up, worker, STROKE["sto"], label="read, gateway endpoint")
    p.edge(worker, media, STROKE["sto"], label="write HLS once")
    p.edge(media, cf, STROKE["sto"], label="OAC")
    p.edge(cf, viewer, STROKE["net"], label="GET HLS")

    # Request: every icon of the row on one centre line, so each edge is straight. The ALB sits in an edge subnet
    # (not drawn: the Cloud group stands for the region); Envoy's pods are its targets (TargetGroupBinding).
    p.text("Request to the web and API", 40, r, 880, 40, size=13, bold=1)
    p.group(f"AWS Cloud · {region}", 520, r + 40, 1320, 400, **CLOUD)
    p.group("EKS cluster svp-&lt;env&gt;", 880, r + 80, 920, 320, gr="eks", stroke="#D05C17", font="#D05C17")
    viewer = p.flat("Viewer", "users", 40, r + 280, cid="rviewer")
    waf = p.icon("WAF web ACL<br>svp-&lt;env&gt;-web, -api", "waf", 320, r + 120, SEC, cid="rwaf", label_top=True)
    cdn = p.icon("CloudFront<br>svp-&lt;env&gt;-web, -api", "cloudfront", 320, r + 280, NET, cid="rcdn")
    alb = p.icon("ALB svp-&lt;env&gt;-edge<br>internal, edge subnets", "application_load_balancer", 600, r + 280, NET, cid="ralb")
    envoy = p.k8s("Envoy proxy<br>Deployment", "deploy", 960, r + 280, size=80, cid="renvoy")
    web = p.k8s("web<br>BFF", "deploy", 1240, r + 120, size=80, cid="rweb")
    gw = p.k8s("gateway<br>Rollout", "deploy", 1240, r + 280, size=80, cid="rgw")
    svc = p.k8s("user, video, engagement,<br>feed services", "deploy", 1520, r + 280, size=80, cid="rsvc")
    p.edge(viewer, cdn, STROKE["net"], label="HTTPS")
    p.edge(waf, cdn, STROKE["sec"], dashed=True, arrow=False)
    p.edge(cdn, alb, STROKE["net"], label="VPC origin", label_pos=-0.6)
    p.edge(alb, envoy, STROKE["net"], label="HTTPS 10443")
    p.edge(envoy, web, STROKE["net"], label="&lt;domain&gt;", exit_=(0.5, 0), entry=(0, 0.5), points=[(1000, r + 160)])
    p.edge(envoy, gw, STROKE["net"], label="api.&lt;domain&gt;")
    p.edge(web, gw, STROKE["net"])
    p.edge(gw, svc, STROKE["net"])
    p.text("CloudFront adds CloudFront-Viewer-Address and the gateway trusts it only on connections from the VPC; web forwards it to "
           "the gateway · the ALB accepts only CloudFront (security group on the origin-facing prefix list) · access logs of the "
           "distributions (none for media on the flat-rate Free plan) and the web ACL logs go to the log archive account",
           40, r + 480, 1800, 80, color=MUTED, valign="top")

    # Telemetry on eks (k3d keeps Loki, Tempo, Prometheus and Grafana in the cluster): the Collector's three outputs
    # fan out from one trunk; the agent and the AMG queries meet AMP on its row.
    p.text("Telemetry: Collector and Prometheus agent to AMP, CloudWatch Logs and X-Ray, read in AMG (eks)", 40, t, 1400, 40, size=13,
           bold=1)
    r1, r2, r3, r4 = t + 160, t + 360, t + 560, t + 760
    p.group("EKS cluster svp-&lt;env&gt; · namespace svp-obs, svp, web", 40, t + 80, 640, 880, gr="eks", stroke="#D05C17", font="#D05C17")
    p.group(f"AWS Cloud · {region}", 800, t + 80, 800, 880, **CLOUD)
    p.group("AWS Account svp-&lt;env&gt;", 840, t + 120, 720, 800, **ACCOUNT)
    apps = p.k8s("", "deploy", 120, r1, size=80, cid="tapps")
    p.text("svp services, web<br>OTLP traces, logs, metrics", 240, r1 + 40, 360, 40)
    col = p.k8s("OTel Collector<br>svp-obs/otel-collector", "deploy", 120, r2, size=80, cid="tcol")
    agent = p.k8s("Prometheus agent ×2<br>svp-obs/kps-prometheus", "sts", 120, r3, size=80, cid="tagent")
    p.text(bullets("Pod Identity role per ServiceAccount, SigV4 on every write",
                   "ACK prometheusservice controller: rules and alert routing to AMP",
                   "Grafana Operator: dashboards, data sources to AMG"), 80, r4 - 40, 560, 120, valign="top")
    xray = p.icon("X-Ray<br>OTLP endpoint", "xray", 960, r1, SEC, cid="txray")
    spans = p.icon("CloudWatch Logs aws/spans<br>Transaction Search", "cloudwatch_2", 1360, r1, SEC, cid="tspans", label_top=True)
    logs = p.icon("CloudWatch Logs<br>/svp/&lt;env&gt;/otel", "cloudwatch_2", 960, r2, SEC, cid="tlogs")
    amp = p.icon("AMP workspace svp-&lt;env&gt;<br>rules, alert manager", "managed_service_for_prometheus", 960, r3, SEC, cid="tamp", label_top=True)
    amg = p.icon("AMG svp-&lt;env&gt;<br>dashboards", "managed_service_for_grafana", 1360, r3, SEC, cid="tamg")
    sns = p.icon("SNS svp-&lt;env&gt;-alarms<br>page, ticket", "sns", 960, r4, INTEG, cid="tsns")
    learner = p.flat("Learner<br>email", "users", 1360, r4, cid="tlearner")
    admins = p.flat("Platform admins, viewers<br>IAM Identity Center", "users", 1680, r3, cid="tadmins")
    p.edge(apps, col, STROKE["net"], label="OTLP")
    trunk = 760
    # labels inside the Account, right of the trunk, so none sits on a border
    route = [(200, r2 + 40), (trunk, r2 + 40), (trunk, r1 + 40), (960, r1 + 40)]
    p.edge(col, xray, STROKE["sec"], label="traces", exit_=(1, 0.5), entry=(0, 0.5), points=route[1:3], label_pos=along(route, (900, r1 + 40)))
    route = [(200, r2 + 40), (trunk, r2 + 40), (trunk, r3 + 40), (960, r3 + 40)]
    p.edge(col, amp, STROKE["sec"], label="metrics", exit_=(1, 0.5), entry=(0, 0.5), points=route[1:3], label_pos=along(route, (900, r3 + 40)))
    p.edge(col, logs, STROKE["sec"], label="logs", exit_=(1, 0.5), entry=(0, 0.5), label_pos=0.7)
    p.edge(agent, amp, STROKE["sec"], label="remote write", exit_=(1, 0.5), entry=(0, 0.5), label_pos=-0.3)
    p.edge(xray, spans, STROKE["sec"], exit_=(1, 0.5), entry=(0, 0.5))
    p.edge(amg, amp, STROKE["sec"], label="PromQL", exit_=(0, 0.5), entry=(1, 0.5))
    p.edge(amg, logs, STROKE["sec"], label="Logs Insights", exit_=(0.5, 0), entry=(1, 0.5), points=[(1400, r2 + 40)])
    p.edge(amg, spans, STROKE["sec"], exit_=(0.5, 0), entry=(0.5, 1), points=[(1400, r2 + 40)])
    p.edge(amp, sns, STROKE["integ"], label="alerts", exit_=(0.5, 1), entry=(0.5, 0))
    p.edge(sns, learner, STROKE["integ"], label="email")
    p.edge(admins, amg, STROKE["sec"], label="SSO", exit_=(0, 0.5), entry=(1, 0.5))
    return p


def pages() -> list[Page]:
    e = envs()
    return [env_page(x) for x in e] + [org_page(), flows(e[0].region)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--pdf", action="store_true", help="export a PDF next to the .drawio file")
    ap.add_argument("--png", type=Path, metavar="DIR", help="export each page as a PNG into DIR (for inspection, not committed)")
    ap.add_argument("--docs", action="store_true", help="export each page as a scale-2 PNG (less past drawio_lib.PNG_MAX_PIXELS) next to the .drawio file (embedded in Markdown, committed)")
    a = ap.parse_args()
    pg = pages()
    out = write(pg, a.out, host="build_svp.py")
    print(f"  {out.relative_to(ROOT) if out.is_relative_to(ROOT) else out} ({len(pg)} pages, {out.stat().st_size // 1024} KB)")
    if a.pdf:
        print(f"  {export(out, 'pdf').name}")
    if a.png:
        a.png.mkdir(parents=True, exist_ok=True)
        for i, x in enumerate(pg, 1):
            print(f"  {export(out, 'png', a.png / f'{out.stem}-{x.name}.png', page=i)}")
    if a.docs:
        for i, x in enumerate(pg, 1):
            print(f"  {export(out, 'png', out.with_name(f'{out.stem}-{x.name}.png'), page=i, scale=2).name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
