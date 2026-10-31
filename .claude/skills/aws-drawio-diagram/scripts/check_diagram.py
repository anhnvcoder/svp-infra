# copied from templates/terraform-base/.claude/skills/aws-drawio-diagram/scripts/check_diagram.py (ecc4349); changed: any ELB load balancer may straddle; Kubernetes icons are icons; --counts and kind_counts(); subnet kind = fill and height
"""Geometry check for draw.io files — catches the mistakes you would otherwise only spot by looking at the picture,
before hand-over. Read-only; never modifies the file.

Checks (the reason behind each rule: SKILL.md):
  1. Valid XML; every page has an mxGraphModel.
  2. Every x/y/width/height of a top-level vertex (icon, container, text, table) is a multiple of the major grid cell
     = 4×gridSize = 40px.
  3. Native tables: child cell x values are cumulative and add up to the table width; row heights plus startSize equal
     the table height; column widths and row heights are also multiples of 40.
  4. An icon lies fully inside every container it intersects; the only exception: a load balancer (ALB, NLB, any ELB
     shape) straddling the border of two touching containers — two public subnet boxes, or two touching AZ rows whose
     public boxes it bridges.
  5. Two icons joined by an orthogonal edge without waypoints must share a center line — a few px off makes a small kink.
  6. Resource icons in the same row (same y) must have the same size.
  7. Edge waypoints snap to the minor grid (gridSize) and share x or y with the connection point on the icon.
  8. An icon comes after every container that intersects it in the file (drawing order) — a filled container created
     later paints over the icon.
  9. A dashed container without fill (AZ) must draw its border — aws4.group with grStroke=0 draws no border.
 10. An icon sits at least one major cell (40px) from the edge of every container enclosing it: touching the border still
     passes check 4 but looks stuck to the frame; if space is needed, widen the container instead of pushing the icon to
     the edge. The straddling ALB is exempt.
 11. Subnet boxes of the same kind (same fill and height) must have the same width: a box with few resources must not be
     narrower than one with many, so the grid looks even. Subnet boxes are recognised by a label containing "subnet";
     public and private boxes (different fills) are different kinds even in one AZ row, and so is a double-height public
     box (ALB straddling).

    python3 .claude/skills/aws-drawio-diagram/scripts/check_diagram.py [--counts] docs/diagrams/terraform-base.drawio
Exits 1 on any error. --counts also prints, per page, how many of each kind `kind_counts()` finds (icon shapes, AZ and
subnet boxes), to compare with the inventory; a spec can import `kind_counts()` to assert them.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

# Every AWS icon except containers: resourceIcon (with resIcon=…) and flat icons (nat_gateway, internet_gateway, users…);
# Kubernetes icons (mxgraph.kubernetes) obey the same placement rules.
ICON_RE = re.compile(r"shape=mxgraph\.(aws4\.(?!group)|kubernetes\.)")
# Load balancer shapes that may straddle two public subnet boxes: ELB manages one node per subnet for every kind.
ELB_RE = re.compile(r"mxgraph\.aws4\.(elastic_load_balancing|application_load_balancer|network_load_balancer|gateway_load_balancer)\b")


def geo(c):
    g = c.find("mxGeometry")
    if g is None:
        return None
    f = lambda k: float(g.get(k)) if g.get(k) is not None else None
    return {"x": f("x"), "y": f("y"), "w": f("width"), "h": f("height"), "el": g}


def off(v, step):
    return v is not None and abs(v / step - round(v / step)) > 1e-6


def check_page(pg) -> list[str]:
    bad = []
    model = pg.find("mxGraphModel")
    if model is None:
        return [f"{pg.get('name')}: missing mxGraphModel (compressed page?)"]
    grid = int(model.get("gridSize") or 10)
    major = grid * 4
    cells = model.find("root").findall("mxCell")
    verts = {c.get("id"): c for c in cells if c.get("vertex") == "1"}
    name = pg.get("name")

    # 2. major grid — every top-level vertex (table cells have relative coordinates, checked separately in 3)
    for cid, c in verts.items():
        g = geo(c)
        if c.get("parent") != "1" or g is None:
            continue
        for k in ("x", "y", "w", "h"):
            if off(g[k], major):
                bad.append(f"{name}: '{c.get('value', '')[:24]}' {k}={g[k]:g} not on the {major}px major grid")

    # 3. tables
    for tid, t in verts.items():
        st = t.get("style") or ""
        if "shape=table" not in st or "shape=tableRow" in st:
            continue
        tg = geo(t)
        lab = f"table '{t.get('value', '')[:20]}'"
        m = re.search(r"startSize=(\d+)", st)
        start = int(m.group(1)) if m else 30
        if start % major:
            bad.append(f"{name}: {lab} startSize={start} not on the {major}px major grid")
        total_h = start
        for r in [r for r in verts.values() if r.get("parent") == tid]:
            rg = geo(r)
            total_h += rg["h"]
            if off(rg["h"], major):
                bad.append(f"{name}: {lab} row height {rg['h']:g} not on the {major}px major grid")
            if abs(rg["w"] - tg["w"]) > 0.5:
                bad.append(f"{name}: {lab} has a row of width {rg['w']:g} ≠ table {tg['w']:g}")
            x = 0.0
            for c in sorted([c for c in verts.values() if c.get("parent") == r.get("id")], key=lambda c: geo(c)["x"] or 0):
                cg = geo(c)
                if abs((cg["x"] or 0) - x) > 0.5:
                    bad.append(f"{name}: {lab} cell '{c.get('value', '')[:16]}' x={cg['x']} ≠ cumulative {x:g}")
                if off(cg["w"], major):
                    bad.append(f"{name}: {lab} column width {cg['w']:g} not on the {major}px major grid")
                if abs(cg["h"] - rg["h"]) > 0.5:
                    bad.append(f"{name}: {lab} cell '{c.get('value', '')[:16]}' height {cg['h']:g} ≠ row {rg['h']:g}")
                x += cg["w"]
            if abs(x - tg["w"]) > 0.5:
                bad.append(f"{name}: {lab} total cell width {x:g} ≠ table {tg['w']:g}")
        if abs(total_h - tg["h"]) > 0.5:
            bad.append(f"{name}: {lab} total row height {total_h:g} ≠ table {tg['h']:g}")

    # 4. an icon lies fully inside every container it intersects (being fully inside Cloud/VPC does not hide a problem
    #    with a child box). The only exception: a load balancer straddling two touching boxes whose union fully covers
    #    the icon — the way AWS draws one ALB or NLB spanning several public subnets (ELB-managed nodes, invisible to the
    #    user): two public boxes side by side, or two touching AZ rows, the icon bridging their public boxes across the
    #    shared AZ border. Nothing else may straddle.
    icons = {cid: c for cid, c in verts.items() if ICON_RE.search(c.get("style") or "") and c.get("parent") == "1"}
    groups = [c for c in verts.values() if "mxgraph.aws4.group" in (c.get("style") or "") and c.get("parent") == "1"]
    inside = lambda x, y, gg: gg["x"] <= x <= gg["x"] + gg["w"] and gg["y"] <= y <= gg["y"] + gg["h"]
    for cid, c in icons.items():
        g = geo(c)
        hits = [geo(grp) for grp in groups
                if geo(grp)["x"] < g["x"] + g["w"] and g["x"] < geo(grp)["x"] + geo(grp)["w"] and geo(grp)["y"] < g["y"] + g["h"] and g["y"] < geo(grp)["y"] + geo(grp)["h"]]
        partial = [gg for gg in hits if not (inside(g["x"], g["y"], gg) and inside(g["x"] + g["w"], g["y"] + g["h"], gg))]
        if not partial:
            continue
        corners = [(x, y) for x in (g["x"], g["x"] + g["w"]) for y in (g["y"], g["y"] + g["h"])] + [(g["x"] + g["w"] / 2, g["y"] + g["h"] / 2)]
        straddle = len(partial) == 2 and ELB_RE.search(c.get("style") or "") and all(any(inside(x, y, gg) for gg in partial) for x, y in corners)
        if not straddle:
            bad.append(f"{name}: icon '{c.get('value', '')[:20]}' overflows a container edge (not fully inside; only a load balancer may straddle two touching containers)")

    # 10. an icon sits at least one major cell from the edge of every container fully enclosing it — touching the border
    #     looks stuck to the frame even though check 4 passes.
    for cid, c in icons.items():
        g = geo(c)
        for grp in groups:
            gg = geo(grp)
            if not (inside(g["x"], g["y"], gg) and inside(g["x"] + g["w"], g["y"] + g["h"], gg)):
                continue
            d = min(g["x"] - gg["x"], g["y"] - gg["y"], gg["x"] + gg["w"] - g["x"] - g["w"], gg["y"] + gg["h"] - g["y"] - g["h"])
            if d < major - 0.5:
                bad.append(f"{name}: icon '{c.get('value', '')[:20]}' is {d:g}px from the edge of container '{grp.get('value', '')[:20]}', needs ≥ {major}px")

    # 11. subnet boxes of the same kind (same fill and height) must have the same width — a box with few resources must
    #     not be narrower than one with many, so the grid looks even. Subnet boxes are recognised by a label containing
    #     "subnet"; the fill tells public from private (both can sit in one AZ row at one height), the height a double-height
    #     public box (ALB straddling) from the boxes in the AZ.
    subnet_widths: dict[tuple, dict[float, str]] = {}
    for grp in groups:
        if "subnet" not in (grp.get("value") or "").lower():
            continue
        gg = geo(grp)
        fill = re.search(r"fillColor=([^;]*)", grp.get("style") or "")
        subnet_widths.setdefault((fill.group(1) if fill else "", gg["h"]), {}).setdefault(gg["w"], grp.get("value", "")[:20])
    for (fill, h), widths in subnet_widths.items():
        if len(widths) > 1:
            bad.append(f"{name}: subnet boxes of fill {fill} and height {h:g} have several widths {sorted(widths)} ({', '.join(widths.values())}) — subnet boxes of the same kind must have the same width")

    # 8. drawing order: an icon must come after every container that intersects it in the file — draw.io paints in file
    #    order, so a filled container created later paints over the icon.
    order = {c.get("id"): i for i, c in enumerate(cells)}
    for cid, c in icons.items():
        g = geo(c)
        for grp in groups:
            gg = geo(grp)
            if gg["x"] < g["x"] + g["w"] and g["x"] < gg["x"] + gg["w"] and gg["y"] < g["y"] + g["h"] and g["y"] < gg["y"] + gg["h"] and order[grp.get("id")] > order[cid]:
                bad.append(f"{name}: icon '{c.get('value', '')[:20]}' is painted over by container '{grp.get('value', '')[:20]}' (the container comes after the icon in the file)")

    # 9. an AZ (dashed container without fill) must have a visible border: aws4.group with grStroke=0 draws no border.
    for grp in groups:
        st = grp.get("style") or ""
        if "dashed=1" in st and "fillColor=none" in st and "grStroke=0" in st:
            bad.append(f"{name}: dashed container '{grp.get('value', '')[:20]}' has grStroke=0 → its border is NOT drawn")

    # 5 + 7. edge alignment / waypoints
    def anchor(c, key, default):
        m = re.search(key + r"=([\d.]+)", c.get("style") or "")
        return float(m.group(1)) if m else default

    for c in cells:
        if c.get("edge") != "1":
            continue
        s, t = verts.get(c.get("source")), verts.get(c.get("target"))
        if s is None or t is None:
            continue
        sg, tg_ = geo(s), geo(t)
        sx, sy = sg["x"] + sg["w"] * anchor(c, "exitX", 0.5), sg["y"] + sg["h"] * anchor(c, "exitY", 0.5)
        tx, ty = tg_["x"] + tg_["w"] * anchor(c, "entryX", 0.5), tg_["y"] + tg_["h"] * anchor(c, "entryY", 0.5)
        arr = c.find("mxGeometry").find("Array") if c.find("mxGeometry") is not None else None
        pts = [(float(p.get("x")), float(p.get("y"))) for p in (arr.findall("mxPoint") if arr is not None else [])]
        label = f"'{s.get('value', '')[:16]}'→'{t.get('value', '')[:16]}'"
        if not pts:
            if s.get("id") not in icons or t.get("id") not in icons:
                continue
            same_row, same_col = abs(sy - ty) < 0.5, abs(sx - tx) < 0.5
            close_row = abs(sy - ty) <= max(sg["h"], tg_["h"]) * 0.6
            close_col = abs(sx - tx) <= max(sg["w"], tg_["w"]) * 0.6
            if (close_row and not same_row) or (close_col and not same_col):
                bad.append(f"{name}: edge {label} is nearly aligned but off by {abs(sy - ty) if close_row else abs(sx - tx):g}px → small kink; align the centers")
        else:
            for x, y in pts:
                if off(x, grid) or off(y, grid):
                    bad.append(f"{name}: edge {label} waypoint ({x:g},{y:g}) not on the {grid}px minor grid")
            first, last = pts[0], pts[-1]
            if abs(first[0] - sx) > 0.5 and abs(first[1] - sy) > 0.5:
                bad.append(f"{name}: edge {label} first waypoint {first} shares neither x nor y with the exit point ({sx:g},{sy:g})")
            if abs(last[0] - tx) > 0.5 and abs(last[1] - ty) > 0.5:
                bad.append(f"{name}: edge {label} last waypoint {last} shares neither x nor y with the entry point ({tx:g},{ty:g})")

    # 6. same row → same size (skips users and badges < 50px)
    rows: dict[float, set] = {}
    for cid, c in icons.items():
        if "aws4.users" in (c.get("style") or "") or (geo(c)["w"] or 0) < 50:
            continue
        g = geo(c)
        rows.setdefault(g["y"], set()).add(g["w"])
    for y, sizes in rows.items():
        if len(sizes) > 1:
            bad.append(f"{name}: row y={y:g} has icons of several sizes {sorted(sizes)} — icons in one row must have the same size")
    return bad


def kind_counts(pg) -> dict[str, int]:
    """Count per kind on one page: an icon by its aws4 shape (resIcon of a resourceIcon, otherwise the flat shape name:
    `rds`, `nat_gateway`, `elastic_load_balancing`…), a Kubernetes icon as `k8s_<prIcon>` (`k8s_ns`, `k8s_deploy`…); `az` for a dashed container without fill (the AZ style); `subnet`
    for a container whose label contains "subnet" (the label rule of check 11)."""
    counts: dict[str, int] = {}
    model = pg.find("mxGraphModel")
    for c in model.find("root").findall("mxCell") if model is not None else []:
        st = c.get("style") or ""
        if c.get("vertex") != "1" or c.get("parent") != "1":
            continue
        if "mxgraph.aws4.group" in st:
            kinds = (["az"] if "dashed=1" in st and "fillColor=none" in st else []) + (["subnet"] if "subnet" in (c.get("value") or "").lower() else [])
        else:
            m = re.search(r"resIcon=mxgraph\.aws4\.(\w+)", st) or re.search(r"shape=mxgraph\.aws4\.(\w+)", st)
            k = "mxgraph.kubernetes." in st and re.search(r"prIcon=(\w+)", st)
            kinds = [m.group(1)] if m else [f"k8s_{k.group(1)}"] if k else []
        for k in kinds:
            counts[k] = counts.get(k, 0) + 1
    return counts


def main() -> int:
    args = sys.argv[1:]
    counts = "--counts" in args
    files = [a for a in args if a != "--counts"]
    if not files:
        print(__doc__)
        return 2
    total = 0
    for f in files:
        try:
            root = ET.fromstring(Path(f).read_text(encoding="utf8"))
        except ET.ParseError as ex:
            print(f"✘ {f}: broken XML — {ex}")
            total += 1
            continue
        for pg in root.findall("diagram"):
            bad = check_page(pg)
            for b in bad:
                print(f"  ✘ {b}")
            total += len(bad)
            print(f"  {Path(f).name} [{pg.get('name')}]: {len(bad)} errors")
            if counts:
                print("    " + (", ".join(f"{k} {n}" for k, n in sorted(kind_counts(pg).items())) or "(no icon, AZ or subnet)"))
    print(f"\nTotal: {total} errors")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
