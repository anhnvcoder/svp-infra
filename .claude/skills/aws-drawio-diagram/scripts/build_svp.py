#!/usr/bin/env python3
"""Generate `docs/diagrams/svp-aws.drawio` (+ PDF, PNG) from a Python spec — the drawio file is GENERATED, edit it here.

Four pages: stg, prd (one function, sizes read from the Terraform of this repository), org (organization, accounts, OUs,
policies, log and detection flows) and flows (release path, upload to playback). Layout as in SKILL.md: rows = AZs, each holding its public, private and database subnet; columns = tiers (outside
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

    @property
    def nat_rows(self) -> list[int]:
        return [0] if self.single_nat else list(range(self.az_count))


def zone_label(env: str) -> str:
    """`zone_name` of aws/accounts/<env>/<env>.auto.tfvars.example (the committed example, never the real file) as a drawn label."""
    zone = tfvars(ROOT / f"aws/accounts/{env}/{env}.auto.tfvars.example")["zone_name"]
    if not zone.endswith("svp.example"):
        raise SystemExit(f"aws/accounts/{env}: zone_name {zone!r} does not end in the example domain svp.example")
    return zone.removesuffix("svp.example") + "&lt;domain&gt;"


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
                       v("valkey_node_count"), logs, v("eks_secrets_kms_encryption"), zone_label(name)))
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
    want = {"users": 1, "route_53": 1, "cloudfront": 1, "waf": 1, "internet_gateway": 1, "elastic_load_balancing": 1, "eks": 1,
            "nat_gateway": len(env.nat_rows), "ec2": 2 * n, "instance2": 1, "rds": 2 if env.multi_az else 1, "managed_streaming_for_kafka": n,
            # endpoints: S3 gateway and guardduty-data interface;
            # s3: media, uploads and the two log archive buckets it writes
            "elasticache": env.cache_nodes, "endpoints": 2, "s3": 4, "secrets_manager": 1, "key_management_service": 1,
            "elastic_block_store": n, "sns": 1, "sqs": 1, "eventbridge": 1, "systems_manager": 1,
            "account": 2, "region": 1, "az": n, "subnet": 3 * n,
            # Kubernetes: a ns icon per frame; a workload icon per svp service, per svp-data workload, and Envoy's
            # proxy Deployment and the Service the NLB targets
            "k8s_ns": FRAMES, "k8s_deploy": len(SVP) + 1 + sum(k == "deploy" for k, _ in SVP_DATA),
            "k8s_job": sum(k == "job" for k, _ in SVP_DATA), "k8s_svc": 1}
    if env.logs:
        want["cloudwatch_2"] = 1
    return want


def org_expected() -> dict[str, int]:
    """What the org page must hold, by check_diagram.kind_counts() kind: the five accounts, one icon per service the
    organization, the log archive and the security account run (see org_page)."""
    return {"account": 5, "organizations": 1, "single_sign_on": 1, "cloudtrail": 1, "eventbridge": 4, "s3": 5, "key_management_service": 1,
            "flow_logs": 2, "waf": 2, "config": 1, "guardduty": 1, "security_hub": 1, "access_analyzer": 1, "sns": 1, "users": 1}


# ---------------------------------------------------------------- geometry of an env page
# Coordinates: the layout section of SKILL.md; why each part sits where it does: its content rules 0–13 (nesting Cloud
# → Account → Region → VPC → AZ → subnet, three subnet tiers per AZ row, EBS in the AZ outside the subnets,
# the NLB across the first two AZ rows, the cluster box over every private box, the database columns ordered so no edge
# crosses a replication line).
CLOUD_X, ACCT_X, GLOBAL_X, REGION_X, IGW_X, VPC_X, AZ_X = 160, 200, 240, 400, 440, 560, 600
PUB_X, PUB_W, NAT_X, NLB_X, EBS_X = 640, 360, 680, 880, 1040
PRIV_X, EKS_X, NODE_X, BASTION_X = 1160, 1400, 1440, 1200
COL, COL_W = (1560, 1800, 2040, 2280), 200
EKS_R, PRIV_R = 2520, 2560
DB_X, DB_R = 2600, 3320
LANE_MSK, LANE_CACHE = 2640, 2680                     # corridors of svp → MSK, svp → ElastiCache
RDS_X, CACHE_X, MSK_X = 2840, 3000, 3160      # clear of the database box's label
CLOUD_Y, ACCT_Y, REGION_Y, CP_Y, DNS_LANE, VPC_Y, SUB_H, AZ_H = 160, 200, 240, 320, 420, 440, 400, 480
CP_X = 2280
AZ_R, VPC_R = DB_R + 40, DB_R + 80
REGION_R, ACCT_R, CLOUD_R = VPC_R + 40, VPC_R + 80, VPC_R + 120
PAGE_W = CLOUD_R + 40


def cidrs(env: Env):
    """Private, public and database CIDR of each AZ, as modules/network computes them."""
    net = ipaddress.ip_network(env.cidr)
    blocks = list(net.subnets(prefixlen_diff=3))
    public = list(blocks[7].subnets(prefixlen_diff=5))
    database = list(blocks[6].subnets(prefixlen_diff=3))
    return ([str(blocks[k]) for k in range(env.az_count)], [str(public[k]) for k in range(env.az_count)],
            [str(database[k]) for k in range(env.az_count)])


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
    nlb_y = a + SUB_H                                     # bottom of the first public box = top of the NLB
    bottom = az[-1] + AZ_H                                # bottom of the last AZ
    ep_y, vpc_b = bottom + 80, bottom + 200
    band_y = vpc_b + 40
    row = band_y + 40                                     # icon row of the band
    lane = band_y + 240                                   # users → uploads, below the band
    region_b = lane + 40
    acct_b = region_b + 40
    log_y = acct_b + 40                                   # the log archive account, under the env's own account
    log_icon, log_b = log_y + 80, log_y + 240
    cloud_b = log_b + 40
    priv, pub, data = cidrs(env)

    p = Page(env.name, PAGE_W, cloud_b + 40)
    p.text(f"{env.name} — EKS cluster svp-{env.name}", 40, 0, 920, 40, size=17, bold=1)
    nat = "one NAT gateway, in the first AZ, for every private subnet" if env.single_nat else "one NAT gateway per AZ"
    p.text(f"{env.region} · {n} AZs, each with a public, a private and a database subnet · {nat} · system node group "
           f"on-demand and Karpenter's nodes ({env.capacity}), one icon each per AZ · API endpoint private only, reached "
           "through Systems Manager port forwarding to the SSM bastion · one NLB across all public subnets, made by the AWS "
           "Load Balancer Controller · EBS volumes in the AZ of their pod's node · TLS certificates from Let's Encrypt "
           "(cert-manager), no ACM · VPC flow logs and WAF logs are written to S3 buckets of the svp-log-archive account",
           40, 40, PAGE_W - 80, 40, color=MUTED)
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
        p.group(f"Public subnet {pub[k]}", PUB_X, sub[k], PUB_W, SUB_H, **{**PUBLIC, "grstroke": True}, cid=f"pub{k}")
        p.group(f"Private subnet {priv[k]}", PRIV_X, sub[k], PRIV_R - PRIV_X, SUB_H, **PRIVATE, cid=f"priv{k}")
        p.group(f"Database subnet {data[k]}", DB_X, sub[k], DB_R - DB_X, SUB_H, **PRIVATE, cid=f"db{k}")
    eks = p.group(f"EKS cluster svp-{env.name}", EKS_X, a, EKS_R - EKS_X, sub[-1] + SUB_H - a, gr="eks", stroke="#D05C17",
                  font="#D05C17", cid="eks")
    p.group("Regional services", VPC_X, band_y, VPC_R - VPC_X, 200, **BAND)
    p.group("AWS Account svp-log-archive · buckets written by this env", ACCT_X, log_y, ACCT_R - ACCT_X, log_b - log_y, **ACCOUNT)

    # namespace frames (boxes, not aws4 containers), every Kubernetes icon wholly inside one private box: first AZ rows
    # +160 and +280, second AZ rows +120 and +240; the fourth column of the second AZ stays free for svp → endpoint
    envoy = frame(p, "envoy-gateway-system", COL[0], a + 160, COL_W, 200)
    workload(p, "deploy", "Envoy proxy", COL[0], a + 240)
    envoy_svc = workload(p, "svc", "Service · type<br>LoadBalancer", COL[0], a + 320)
    dns = frame(p, "external-dns,<br>cert-manager", COL[1], a + 160, COL_W, 80)
    p.text("ExternalDNS · cert-manager<br>(Let's Encrypt, DNS-01)", COL[1], a + 200, COL_W, 40, align="center")
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
    p.text(bullets("Prometheus, Alertmanager, Grafana", "Loki, Tempo, Pyroscope", "OTel Collector", "GlitchTip"),
           COL[2], b + 200, COL_W, 120)
    mid = COL[3] + 120                                    # x of svp → S3 endpoint (centre of the endpoint)

    # global services of the account, left of the Region; users outside the Cloud
    users = p.flat("Users", "users", 40, nlb_y, cid="users")
    r53 = p.icon(f"Route 53 · {env.zone}", "route_53", GLOBAL_X, nlb_y, NET, cid="r53")
    waf = p.icon("WAF web ACL · CloudFront scope<br>(us-east-1, flat-rate Free)", "waf", GLOBAL_X, row - 160, SEC, cid="waf")
    cf = p.icon("CloudFront · *.cloudfront.net", "cloudfront", GLOBAL_X, row, NET, cid="cf")
    igw = p.flat("Internet gateway", "internet_gateway", IGW_X, nlb_y, VPC_PURPLE, cid="igw")
    cp = p.icon("EKS control plane · AWS managed", "eks", CP_X, CP_Y, COMP, cid="cp", label_top=True)
    nlb = p.icon("Network Load Balancer", "elastic_load_balancing", NLB_X, nlb_y, NET, cid="nlb")
    ep = p.flat("S3 gateway endpoint", "endpoints", mid - 40, ep_y, VPC_PURPLE, cid="s3ep")
    gd_ep = p.flat("GuardDuty interface endpoint<br>guardduty-data, 443 from the VPC", "endpoints", mid + 240, ep_y, VPC_PURPLE, cid="gdep")
    waf_logs = p.icon("S3 aws-waf-logs-svp<br>WAF logs, us-east-1", "s3", GLOBAL_X, log_icon, STO, cid="waflogs")
    p.text("SSE-KMS with alias/svp-log-archive · blocked from public access · written by service principals of the "
           "organization (aws:SourceOrgID)", GLOBAL_X + 240, log_icon, 1040, 80, color=MUTED)
    flow_logs = p.icon("S3 svp-flowlogs<br>VPC flow logs", "s3", ACCT_R - 120, log_icon, STO, cid="flowlogs")

    nats = {k: p.flat("NAT gateway", "nat_gateway", NAT_X, sub[k] + 40, VPC_PURPLE, cid=f"nat{k}") for k in env.nat_rows}
    nodes = [p.icon("System node group<br>on-demand", "ec2", NODE_X, sub[k] + 40, COMP, cid=f"node{k}") for k in range(n)]
    # below the system node, clear of the kube-system → EBS line that crosses the node column of the second AZ at +200
    karpenter = [p.icon(f"Karpenter node<br>{env.capacity}", "ec2", NODE_X, sub[k] + 240, COMP, cid=f"karp{k}") for k in range(n)]
    # private subnet of the first AZ, left of the cluster box, below the node → NAT line
    bastion = p.flat("SSM bastion · t4g.nano", "instance2", BASTION_X, a + 160, COMP[0], cid="bastion")
    ebs = [p.icon("EBS gp3 · PVCs", "elastic_block_store", EBS_X, sub[k] + 160, STO, cid=f"ebs{k}") for k in range(n)]

    # database tier: RDS, ElastiCache nodes (primary first), one MSK broker per AZ
    db = p.icon("RDS PostgreSQL" + (" primary" if env.multi_az else ""), "rds", RDS_X, a + 280, DB, cid="rds0")
    standby = p.icon("RDS standby", "rds", RDS_X, b + 280, DB, cid="rds1") if env.multi_az else None
    caches = [p.icon("ElastiCache Valkey" + ("" if env.cache_nodes == 1 else " primary" if k == 0 else " replica"),
                     "elasticache", CACHE_X, sub[k] + 160, DB, cid=f"cache{k}") for k in range(env.cache_nodes)]
    brokers = [p.icon("MSK broker", "managed_streaming_for_kafka", MSK_X, sub[k] + 40, ANA, cid=f"msk{k}") for k in range(n)]

    media = p.icon("S3 media", "s3", 600, row, STO, cid="media")
    # entered from below by the browser
    uploads = p.icon("S3 uploads<br>GuardDuty malware scan", "s3", 760, row, STO, cid="uploads", label_top=True)
    p.icon(f"Secrets Manager<br>RDS master, svp/{env.name}/*,<br>AmazonMSK_*", "secrets_manager", 1000, row, SEC, cid="sm")
    keys = "Terraform state, RDS,<br>MSK, SNS of the alarms" + ("<br>EKS Secrets" if env.kms_eks else "")
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

    # request path: DNS, IGW, NLB, Envoy, services, databases. IGW → NLB → Envoy run 20 above the shared AZ border,
    # in the bottom margin of the first AZ, never on the dashed line itself (the controllers' edge runs 20 below it).
    p.edge(users, r53)
    p.edge(r53, igw, STROKE["net"])
    p.edge(igw, nlb, STROKE["net"], exit_=(1, 0.25), entry=(0, 0.25))
    p.edge(nlb, envoy_svc, STROKE["net"], label="TCP 443", exit_=(1, 0.25), entry=(0.5, 1), points=[(COL[0] + 20, nlb_y + 20)])
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
    p.edge(nats[0], igw, STROKE["vpc"], dashed=True, exit_=(0, 0.5), entry=(0.5, 0), points=[(IGW_X + 40, a + 80)])

    # controllers that create AWS resources. kube-system → NLB rises right of the node column into the top margin of
    # the second AZ, then left into the NLB's side: from below it would cross every node → NAT line of a NAT per AZ.
    # Its label sits left of the cluster: the middle of the route would fall on the cluster's border.
    p.edge(csi, nlb, STROKE["net"], dashed=True, label="creates NLB", exit_=(0.25, 0), entry=(1, 0.75),
           points=[(COL[0] + 50, nlb_y + 60)], label_pos=0.33)
    p.edge(csi, ebs[1], STROKE["sto"], dashed=True, label="volumes", exit_=(0, 0.5), entry=(1, 0.5))
    p.edge(csi, karpenter[1], COMP[0], dashed=True, exit_=(0.25, 1), entry=(1, 0.5), points=[(COL[0] + 50, b + 280)])
    p.edge(dns, r53, STROKE["net"], dashed=True, label="records, DNS-01", exit_=(0.5, 0), entry=(0.5, 0),
           points=[(COL[1] + 100, DNS_LANE), (GLOBAL_X + 40, DNS_LANE)])

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
    route = [(60, nlb_y + 80), (60, lane), (800, lane), (800, row + 80)]
    p.edge(users, uploads, STROKE["sto"], label="POST presigned form", exit_=(0.25, 1), entry=(0.5, 1), points=route[1:3],
           label_pos=along(route, (480, lane)))
    p.edge(users, cf, STROKE["net"], label="GET HLS", exit_=(0.75, 1), entry=(0, 0.5), points=[(100, row + 40)])
    p.edge(waf, cf, STROKE["sec"], dashed=True, arrow=False, exit_=(0.5, 1), entry=(0.5, 0))

    # logs to the log archive account: WAF down the corridor left of the account, the VPC down the one right of
    # the Region
    p.edge(waf, waf_logs, STROKE["sec"], dashed=True, label="logs", exit_=(0, 0.5), entry=(0, 0.5),
           points=[(ACCT_X - 20, row - 120), (ACCT_X - 20, log_icon + 40)], label_pos=0.6)
    lane_x, out_y = VPC_R + 60, bottom + 100
    p.edge("vpc", flow_logs, STROKE["sto"], dashed=True, label="flow logs", exit_=(1, (out_y - VPC_Y) / (vpc_b - VPC_Y)), entry=(1, 0.5),
           points=[(lane_x, out_y), (lane_x, log_icon + 40)], label_pos=0.5)
    p.edge(cf, media, STROKE["sto"], label="OAC")

    # alarms and interruptions, inside the band
    if cw:
        p.edge(cw, sns, STROKE["integ"], label="alarm, OK")
    p.edge(events, queue, STROKE["integ"])
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

    p = Page("org", 2840, 2240)
    p.text("org — organization, accounts and security flows", 40, 0, 920, 40, size=17, bold=1)
    p.text("The management account holds the organization, IAM Identity Center and the organization trail · accounts in OUs as in the "
           "AWS Security Reference Architecture: Security (log archive, security tooling) and Workloads (Prod, NonProd) · every "
           "account also runs the baseline (S3 Block Public Access, EBS default encryption, Config recorder to svp-config)",
           40, 40, 2760, 40, color=MUTED)
    p.text("Green: logs to the log archive account · red: detection and events to the security account, then SNS and email · "
           "policies on the root reach every member account (SCP, RCP) or every account (declarative, tag)", 40, 80, 2760, 40, color=MUTED)

    p.group("AWS Organization · root", 40, 160, 2760, 2040, **ORG)
    p.box("<b>On the root: service control policies</b>" + bullets(*scp), 80, 240, 840, 200, "#F7F7F7", MUTED, valign="top")
    p.box("<b>On the root: resource control, declarative, tag</b>" + bullets(*rest), 960, 240, 840, 200, "#F7F7F7", MUTED, valign="top")
    p.box("<b>Organization features</b>" + bullets(
        "Centralized root access: member accounts hold no root credentials",
        "Delegated administrator svp-security: GuardDuty, Security Hub, Config, IAM Access Analyzer",
        "Baseline roots apply from the management account through OrganizationAccountAccessRole"),
        1840, 240, 880, 200, "#F7F7F7", MUTED, valign="top")

    # management account (left), Security OU (middle), Workloads OU (right); rows of the log archive buckets at BUCKET
    p.group("Management account", 80, 560, 600, 1040, **ACCOUNT)
    p.group("OU Security", 760, 560, 880, 1560, **OU)
    p.group("svp-log-archive", 800, 640, 800, 880, **ACCOUNT)
    p.group("svp-security · delegated administrator", 800, 1560, 800, 520, **ACCOUNT)
    p.group("OU Workloads", 2000, 560, 720, 1560, **OU)
    p.group("OU Prod", 2040, 600, 640, 720, **OU)
    p.group("svp-prd", 2080, 680, 560, 560, **ACCOUNT)
    p.group("OU NonProd", 2040, 1360, 640, 760, **OU)
    p.group("svp-stg", 2080, 1440, 560, 560, **ACCOUNT)
    p.text("<b>On OU Prod:</b> " + ", ".join(on_prod), 2080, 1240, 560, 40)

    # management account
    p.icon("AWS Organizations<br>root, OUs, member accounts", "organizations", 320, 720, SEC, cid="orgs")
    p.icon("IAM Identity Center<br>SvpAdmin, SvpReadOnly, SvpLogReader", "single_sign_on", 320, 880, SEC, cid="idc")
    trail = p.icon("CloudTrail organization trail<br>management events, S3 data events of prd", "cloudtrail", 320, 1040, SEC, cid="trail")
    m_fwd = p.icon("EventBridge svp-security-* rules<br>forwarder role", "eventbridge", 320, 1360, INTEG, cid="mfwd", label_top=True)

    # log archive: one bucket per kind of log, in a column the sources reach from both sides
    b = {"cloudtrail": 720, "config": 880, "flowlogs": 1040, "waf": 1200, "guardduty": 1360}
    buckets = {
        "cloudtrail": p.icon("S3 svp-cloudtrail<br>organization trail, Object Lock", "s3", 1000, b["cloudtrail"], STO, cid="b_trail"),
        "config": p.icon("S3 svp-config<br>recorder of every account", "s3", 1000, b["config"], STO, cid="b_config"),
        "flowlogs": p.icon("S3 svp-flowlogs<br>VPC flow logs", "s3", 1000, b["flowlogs"], STO, cid="b_flow"),
        "waf": p.icon("S3 aws-waf-logs-svp<br>WAF logs, us-east-1", "s3", 1000, b["waf"], STO, cid="b_waf"),
        "guardduty": p.icon("S3 svp-guardduty<br>finding export", "s3", 1000, b["guardduty"], STO, cid="b_gd", label_top=True),
    }
    p.icon("KMS alias/svp-log-archive<br>a key in each bucket region", "key_management_service", 1320, b["config"], SEC, cid="kms")

    # security account
    p.icon("Config aggregator<br>whole organization", "config", 840, 1640, SEC, cid="agg")
    gd = p.icon("GuardDuty<br>organization, 2 regions", "guardduty", 1000, 1640, SEC, cid="gd")
    hub = p.icon("Security Hub<br>FSBP, CIS v5", "security_hub", 1160, 1640, SEC, cid="hub", label_top=True)
    p.icon("IAM Access Analyzer<br>organization", "access_analyzer", 1320, 1640, SEC, cid="aa")
    bus = p.icon("EventBridge bus<br>svp-security-events", "eventbridge", 1320, 1880, INTEG, cid="bus", label_top=True)
    sns = p.icon("SNS svp-security-alarms", "sns", 1480, 1880, INTEG, cid="sns")
    learner = p.flat("Learner<br>email", "users", 1680, 1880, cid="learner")

    # workload accounts: the log sources of an env and its event forwarder
    sources = {}
    for env, top in (("prd", 760), ("stg", 1520)):
        sources[env] = (
            p.flat("VPC flow logs", "flow_logs", 2160, top, VPC_PURPLE, cid=f"{env}_flow"),
            p.icon("WAF web ACL logging<br>aws-waf-logs-svp", "waf", 2160, top + 160, SEC, cid=f"{env}_waf"),
            p.icon("EventBridge svp-security-* rules<br>forwarder role", "eventbridge", 2160, top + 320, INTEG, cid=f"{env}_fwd", label_top=True))

    green, integ, sec = STROKE["sto"], STROKE["integ"], STROKE["sec"]
    # logs: left lane x=720 from the management account, lanes right of the Security OU from the workload accounts
    p.edge(trail, buckets["cloudtrail"], green, exit_=(1, 0.5), entry=(0, 0.5), points=[(720, 1080), (720, b["cloudtrail"] + 40)])
    p.edge(gd, buckets["guardduty"], green, exit_=(0.5, 0), entry=(0.5, 1))
    lanes = {("prd", "flow"): 1840, ("prd", "waf"): 1860, ("stg", "waf"): 1880, ("stg", "flow"): 1900}
    ys = {"prd": 760, "stg": 1520}
    for env in ("prd", "stg"):
        flow, waf, _ = sources[env]
        for src, kind, dy in ((flow, "flow", 0), (waf, "waf", 160)):
            lane = lanes[(env, kind)]
            p.edge(src, buckets["flowlogs" if kind == "flow" else "waf"], green, exit_=(0, 0.5), entry=(1, 0.5),
                   points=[(lane, ys[env] + dy + 40), (lane, b["flowlogs" if kind == "flow" else "waf"] + 40)])
    # detection: GuardDuty and Access Analyzer findings into Security Hub, Security Hub and every account's rules
    # to the bus
    p.edge(gd, hub, sec, label="findings")
    p.edge("aa", hub, sec)
    p.edge(hub, bus, integ, exit_=(0.5, 1), entry=(0, 0.5))
    p.edge(m_fwd, bus, integ, exit_=(1, 0.5), entry=(0.5, 1), points=[(720, 1400), (720, 2040), (1360, 2040)])
    for env, lane in (("prd", 1920), ("stg", 1940)):
        fwd = sources[env][2]
        p.edge(fwd, bus, integ, exit_=(0, 0.5), entry=(0.5, 1),
               points=[(lane, ys[env] + 360), (lane, 2040), (1360, 2040)])
    p.edge(bus, sns, integ)
    p.edge(sns, learner, integ, label="email")
    return p


def flows(region: str) -> Page:
    p = Page("flows", 1880, 840)
    p.text("Flows — release path and upload to playback", 40, 0, 920, 40, size=17, bold=1)
    p.text("Release: commit → signed image → svp-gitops → Argo CD", 40, 120, 880, 40, size=13, bold=1)
    p.group(f"AWS Cloud · {region}", 1360, 120, 480, 320, **CLOUD)
    p.group("EKS cluster svp-&lt;env&gt;", 1400, 160, 400, 240, gr="eks", stroke="#D05C17", font="#D05C17")
    p.text("Upload to playback", 40, 480, 880, 40, size=13, bold=1)
    # Cloud: the buckets (regional) and the cluster; CloudFront is global, outside it (content rule 3). Every edge label
    # lies clear of the borders its edge crosses.
    p.group(f"AWS Cloud · {region}", 160, 520, 1160, 280, **CLOUD)
    p.group("EKS cluster svp-&lt;env&gt;", 720, 560, 200, 200, gr="eks", stroke="#D05C17", font="#D05C17")

    gh = p.box("<b>GitHub · svp-backend, svp-frontend</b><br>images.yml: build, scan, sign, attest", 40, 200, 320, 80, "#F7F7F7", MUTED, align="center")
    ghcr = p.box("<b>GHCR</b><br>images by digest · cosign, vuln, SLSA provenance", 480, 200, 320, 80, "#F7F7F7", MUTED, align="center")
    git = p.box("<b>GitHub · svp-gitops</b><br>envs/&lt;env&gt;/images, charts.yaml · PR by the bot", 920, 200, 320, 80, "#F7F7F7", MUTED, align="center")
    argo = frame(p, "argocd", 1440, 200, 320, 80)
    p.text("Argo CD: syncs values, charts", 1440, 240, 320, 40, align="center")
    p.edge(gh, ghcr, label="push, sign")
    p.edge(ghcr, git, label="promote digest (PR)")
    p.edge(git, argo)   # no label: the Cloud border crosses its middle; the argocd frame says what it syncs
    p.edge(argo, ghcr, MUTED, dashed=True, label="pull by digest, through NAT", exit_=(0.5, 1), entry=(0.5, 1), points=[(1600, 340), (640, 340)])

    creator = p.flat("Creator", "users", 40, 600, cid="creator")
    up = p.icon("S3 uploads", "s3", 320, 600, STO, cid="up")
    worker = p.k8s("media-worker<br>Deployment · KEDA", "deploy", 760, 600, size=80, cid="worker")
    media = p.icon("S3 media", "s3", 1200, 600, STO, cid="med")
    cf = p.icon("CloudFront", "cloudfront", 1480, 600, NET, cid="cdn")
    viewer = p.flat("Viewer", "users", 1720, 600, cid="viewer")
    p.edge(creator, up, STROKE["sto"], label="POST presigned")
    p.edge(up, worker, STROKE["sto"], label="read, gateway endpoint")
    p.edge(worker, media, STROKE["sto"], label="write HLS once")
    p.edge(media, cf, STROKE["sto"], label="OAC")
    p.edge(cf, viewer, STROKE["net"], label="GET HLS")
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
