#!/usr/bin/env python3
"""Icon count of each env page of `docs/diagrams/svp-aws.drawio` against the sizes of the Terraform: AZ and subnet boxes,
NAT gateways, node group icons (one per AZ), RDS (1, or 2 with Multi-AZ) and every other kind on the page. Offline: the
sizes come from aws/envs/stg/stg.tfvars and the prd column of the module READMEs (build_svp.envs()), never from a plan.
The drawing is read back from the file, so a spec that draws the wrong number fails here even though it read the right size.

    python3 .claude/skills/aws-drawio-diagram/scripts/check_svp_counts.py [docs/diagrams/svp-aws.drawio]
Exits 1 on any mismatch.
"""
from __future__ import annotations

import sys
from pathlib import Path
from xml.etree import ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_svp import OUT, envs, expected  # noqa: E402
from check_diagram import kind_counts  # noqa: E402


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else OUT
    pages = {pg.get("name"): pg for pg in ET.fromstring(path.read_text(encoding="utf8")).findall("diagram")}
    bad = 0
    for env in envs():
        pg = pages.get(env.name)
        if pg is None:
            print(f"  ✘ {path.name}: no page {env.name}")
            bad += 1
            continue
        want, got = expected(env), kind_counts(pg)
        diff = {k: (want.get(k, 0), got.get(k, 0)) for k in sorted(set(want) | set(got)) if want.get(k, 0) != got.get(k, 0)}
        for k, (w, g) in diff.items():
            print(f"  ✘ {env.name}: {k} drawn {g}, expected {w}")
        bad += len(diff)
        print(f"  {path.name} [{env.name}]: {env.az_count} AZs, {len(env.nat_rows)} NAT, {expected(env)['rds']} RDS, "
              f"{env.capacity} → {len(diff)} mismatches")
    print(f"\nTotal: {bad} mismatches")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
