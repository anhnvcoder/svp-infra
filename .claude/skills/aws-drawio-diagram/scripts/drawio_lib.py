# copied from templates/terraform-base/.claude/skills/aws-drawio-diagram/scripts/drawio_lib.py (ecc4349); changed: export() finds the draw.io CLI through $DRAWIO, PATH, then the macOS app; Page.k8s() draws Kubernetes icons; edge(label_pos=…)
"""drawio_lib — generates `.drawio` files (plus PDF/PNG) in the terraform-base AWS infrastructure diagram style.

Usage: write a short Python spec file that calls `Page` and then `write()`; see `build_terraform_base.py` for an example.

Geometry rules (the reason behind each rule is in SKILL.md):
  • draw.io grid: minor cell 10px, MAJOR cell 40px (4×4 minor cells). EVERY x/y/width/height of a top-level vertex is
    a multiple of 40, tables and text blocks included — otherwise the shape's lines miss the grid's bold lines and the
    drawing looks "off-grid".
  • Icons are 80×80 (exactly 2×2 major cells) → the icon center sits on a bold grid line and edges run along the grid.
    Badges are 40×40.
  • An orthogonal edge WITHOUT waypoints is straight only when the two icons share a center (same row means same y and
    same size). Waypoints (when unavoidable) are multiples of 10 and must share x or y with the connection point.
The library enforces only the multiple-of-40 and icon-size rules; `check_diagram.py` measures the rest on the generated file.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from xml.sax.saxutils import quoteattr

G = 40            # major cell
ICON = 80         # icon, 2×2 major cells
BADGE = 40        # small attached icon (WAF…), 1 major cell
GRID = 10         # minor cell — waypoints snap to it
DRAWIO_APP = Path("/Applications/draw.io.app/Contents/MacOS/draw.io")   # macOS app, last resort of drawio_cli()

# ---------------------------------------------------------------- style (kept verbatim from terraform-base.drawio)
_PTS = "points=[[0,0,0],[0.25,0,0],[0.5,0,0],[0.75,0,0],[1,0,0],[0,1,0],[0.25,1,0],[0.5,1,0],[0.75,1,0],[1,1,0],[0,0.25,0],[0,0.5,0],[0,0.75,0],[1,0.25,0],[1,0.5,0],[1,0.75,0]];"
_ICON = ("sketch=0;" + _PTS + "outlineConnect=0;fontColor=#232F3E;gradientColor={grad};gradientDirection=north;fillColor={fill};"
         "strokeColor=#ffffff;dashed=0;verticalLabelPosition=bottom;verticalAlign=top;align=center;html=1;fontSize=11;fontStyle=0;"
         "aspect=fixed;shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.{icon};")
_FLAT = ("sketch=0;outlineConnect=0;fontColor=#232F3E;gradientColor=none;fillColor={fill};strokeColor=none;dashed=0;"
         "verticalLabelPosition=bottom;verticalAlign=top;align=center;html=1;fontSize=11;fontStyle=0;aspect=fixed;pointerEvents=1;"
         "shape=mxgraph.aws4.{icon};")
_GROUP = ("sketch=0;outlineConnect=0;gradientColor=none;html=1;whiteSpace=wrap;fontSize=12;fontStyle=0;container=1;pointerEvents=0;"
          "collapsible=0;recursiveResize=0;shape=mxgraph.aws4.group;grIcon=mxgraph.aws4.{gr};{grstroke}strokeColor={stroke};"
          "fillColor={fill};fontColor={font};verticalAlign=top;align=left;spacingLeft=30;dashed={dashed};strokeWidth={sw};")
# Kubernetes icon of draw.io's official Kubernetes library; kubernetesLabel=1 writes the kind (ns, deploy, svc…) inside the icon.
_K8S = ("aspect=fixed;sketch=0;html=1;dashed=0;whitespace=wrap;verticalLabelPosition=bottom;verticalAlign=top;fillColor=#2875E2;"
        "fontSize=11;fontColor=#232F3E;"
        "strokeColor=#ffffff;points=[[0.005,0.63,0],[0.1,0.2,0],[0.9,0.2,0],[0.5,0,0],[0.995,0.63,0],[0.72,0.99,0],[0.5,1,0],[0.28,0.99,0]];"
        "shape=mxgraph.kubernetes.icon2;kubernetesLabel=1;prIcon={kind};")
_TEXT = "text;html=1;align={align};verticalAlign={valign};whiteSpace=wrap;fontSize={size};fontStyle={bold};fontColor={color};"
_BOX = ("rounded=1;whiteSpace=wrap;html=1;fillColor={fill};strokeColor={stroke};align={align};verticalAlign={valign};spacing=10;"
        "fontSize={size};fontStyle={bold};fontColor={color};")
_EDGE = "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;strokeColor={color};endArrow=blockThin;endFill=1;{dashed}"
_TABLE = ("shape=table;startSize=40;container=1;collapsible=0;childLayout=tableLayout;fixedRows=1;rowLines=1;columnLines=1;"
          "fontStyle=1;fontSize=12;align=center;resizeLast=1;html=1;strokeColor=#5A6C86;fillColor=#FFFFFF;fontColor=#232F3E;")
_TROW = ("shape=tableRow;horizontal=0;startSize=0;swimlaneHead=0;swimlaneBody=0;fillColor=none;collapsible=0;dropTarget=0;"
         "points=[[0,0.5],[1,0.5]];portConstraint=eastwest;top=0;left=0;right=0;bottom=0;")
_TCELL = ("shape=partialRectangle;connectable=0;fillColor={fill};top=0;left=0;bottom=0;right=0;align={align};spacingLeft=8;"
          "spacingRight=8;overflow=hidden;html=1;fontSize=11;{bold}fontColor=#232F3E;strokeColor=#D8DDE3;")

# colors per AWS service group (fill, gradient) — matching draw.io's aws4 palette
NET = ("#5A30B5", "#945DF2")      # networking (Route 53, ALB, CloudFront)
SEC = ("#C7131F", "#F54749")      # security / management (WAF, SSM, CloudWatch, SNS alarm)
COMP = ("#D05C17", "#F78E04")     # compute / containers (EC2, ECS, Lambda, ECR)
DB = ("#3334B9", "#4D72F3")       # database (RDS, ElastiCache)
STO = ("#277116", "#60A337")      # storage (S3)
INTEG = ("#BC1356", "#F34482")    # app integration (SQS, SES, SNS, EventBridge)
DEV = ("#3334B9", "#4D72F3")      # developer tools (CodeDeploy, git)
INK = "#232F3E"                   # default text / edge
MUTED = "#5A6C86"                 # secondary text
GRAY = "#232F3D"                  # flat icon (users)
VPC_PURPLE = "#8C4FFF"            # flat networking icon (IGW, NAT)
K8S = "#2875E2"                   # Kubernetes icon blue — namespace frames take it as their stroke
STROKE = {"net": "#5A30B5", "sec": "#C7131F", "comp": "#232F3E", "db": "#3334B9", "sto": "#277116", "integ": "#BC1356", "vpc": "#8C4FFF"}

# common containers: (grIcon, stroke, fill, font, dashed, grstroke)
CLOUD = dict(gr="group_aws_cloud_alt", stroke="#232F3E")
VPC = dict(gr="group_vpc2", stroke="#8C4FFF", font="#AAB7B8")
PUBLIC = dict(gr="group_security_group", stroke="#7AA116", fill="#F2F6E8", font="#248814", grstroke=False)
PRIVATE = dict(gr="group_security_group", stroke="#00A4A6", fill="#E6F6F7", font="#147EBA", grstroke=False)
# AZ: the blue dashed border must be on (`grstroke=True`). For the aws4.group shape, `grStroke=0` draws NO border at all,
# not just no icon border. 1px stroke. Subnets keep a fill without a border because the fill already sets the area apart.
AZ = dict(gr="group_security_group", stroke="#147EBA", dashed=1, grstroke=True)
BAND = dict(gr="group_security_group", stroke="#5A6C86", fill="#F7F7F7", dashed=1, grstroke=False)


def _major(**kw):
    for k, v in kw.items():
        if v % G:
            raise ValueError(f"{k}={v} not on the {G}px major grid (multiple of {G})")


def bullets(*items: str) -> str:
    """Multi-item note: one item per line (HTML list). A single paragraph holding several items does not let the reader
    tell where each item starts. A text box holding a list needs ~16px per line at size 11; an item longer than the width
    wraps — work out the height, then round it up to a multiple of 40."""
    return '<ul style="margin:0;padding-left:16px">' + "".join(f"<li>{i}</li>" for i in items) + "</ul>"


class Page:
    """One draw.io page. Absolute coordinates, origin (0,0) at the top left; the page height grows to fit tables."""

    def __init__(self, name: str, w: int, h: int, font: str | None = None):
        """font: fontFamily added to EVERY style that carries text. Required when the page has Japanese/Chinese/Korean
        text: with the default (Helvetica) the draw.io CLI PDF embeds a broken fallback font — kana survive, kanji vanish
        in every viewer, while the PNG stays correct. "Hiragino Sans" for Japanese; for English/Vietnamese leave None or "Arial"."""
        _major(w=w, h=h)
        self.name, self.parts, self.n, self.w, self.h, self.font = name, [], 0, w, h, font

    def _id(self, hint):
        # contains "_" so it cannot clash with ids the spec sets itself (e.g. cid="r53" vs table row 53) — a duplicate id makes the checker read the wrong geometry
        self.n += 1
        return f"{hint}_{self.n}"

    def _font(self, style):
        return style + f"fontFamily={self.font};" if self.font else style

    def _cell(self, cid, value, style, parent, geo):
        style = self._font(style)
        self.parts.append(f'<mxCell id={quoteattr(cid)} value={quoteattr(value)} style={quoteattr(style)} vertex="1" parent={quoteattr(parent)}>'
                          f'<mxGeometry {geo} as="geometry"/></mxCell>')
        return cid

    # ---- vertex
    def group(self, label, x, y, w, h, gr, stroke, fill="none", font=None, dashed=0, grstroke=True, sw=1, cid=None):
        _major(x=x, y=y, w=w, h=h)
        st = _GROUP.format(gr=gr, grstroke="" if grstroke else "grStroke=0;", stroke=stroke, fill=fill, font=font or stroke, dashed=dashed, sw=sw)
        return self._cell(cid or self._id("g"), label, st, "1", f'x="{x}" y="{y}" width="{w}" height="{h}"')

    def icon(self, label, icon, x, y, color, size=ICON, cid=None, label_top=False):
        """label_top: put the label ABOVE the icon — for a badge sitting right above another box's label (WAF above the label of the public subnet in the row below)."""
        _major(x=x, y=y, size=size)
        st = _ICON.format(fill=color[0], grad=color[1], icon=icon)
        if label_top:
            st = st.replace("verticalLabelPosition=bottom;verticalAlign=top;", "verticalLabelPosition=top;verticalAlign=bottom;")
        return self._cell(cid or self._id("i"), label, st, "1", f'x="{x}" y="{y}" width="{size}" height="{size}"')

    def flat(self, label, icon, x, y, fill=GRAY, size=ICON, cid=None):
        _major(x=x, y=y, size=size)
        return self._cell(cid or self._id("i"), label, _FLAT.format(fill=fill, icon=icon), "1", f'x="{x}" y="{y}" width="{size}" height="{size}"')

    def k8s(self, label, kind, x, y, size=BADGE, cid=None):
        """Kubernetes object icon (kind: ns, deploy, sts, ds, svc, ing, pod, node, pvc, secret, cm, hpa, job…). 40px by default:
        it marks a namespace frame or the main workload inside it, where an 80px icon would not fit."""
        _major(x=x, y=y, size=size)
        return self._cell(cid or self._id("k"), label, _K8S.format(kind=kind), "1", f'x="{x}" y="{y}" width="{size}" height="{size}"')

    def text(self, label, x, y, w, h, size=11, bold=0, color=INK, align="left", valign="middle", cid=None):
        _major(x=x, y=y, w=w, h=h)
        st = _TEXT.format(size=size, bold=bold, color=color, align=align, valign=valign)
        return self._cell(cid or self._id("t"), label, st, "1", f'x="{x}" y="{y}" width="{w}" height="{h}"')

    def box(self, label, x, y, w, h, fill, stroke, color=INK, size=11, bold=0, align="left", valign="middle", cid=None):
        _major(x=x, y=y, w=w, h=h)
        st = _BOX.format(fill=fill, stroke=stroke, align=align, valign=valign, size=size, bold=bold, color=color)
        return self._cell(cid or self._id("b"), label, st, "1", f'x="{x}" y="{y}" width="{w}" height="{h}"')

    # ---- edge
    def edge(self, src, dst, color=INK, dashed=False, label="", exit_=None, entry=None, points=(), arrow=True, cid=None, label_pos=None):
        """exit_/entry: (tx, ty) as 0..1 fractions along the icon's sides. points: absolute waypoints, multiples of 10 —
        use only when the automatic route crosses another icon or overlaps another edge. arrow=False: no arrowhead
        (a relationship without a clear direction, e.g. Redis cluster-mode replication when the API does not return node roles).
        label_pos: where the label sits along the whole route, -1 (source) .. 1 (target), 0 (the default) being its middle —
        for a bent route whose middle falls on a container border."""
        for x, y in points:
            if x % GRID or y % GRID:
                raise ValueError(f"waypoint ({x},{y}) not on the {GRID}px minor grid")
        st = self._font(_EDGE.format(color=color, dashed="dashed=1;" if dashed else ""))
        if not arrow:
            st = st.replace("endArrow=blockThin;endFill=1;", "endArrow=none;")
        if exit_:
            st += f"exitX={exit_[0]};exitY={exit_[1]};exitDx=0;exitDy=0;"
        if entry:
            st += f"entryX={entry[0]};entryY={entry[1]};entryDx=0;entryDy=0;"
        pts = "".join(f'<mxPoint x="{x}" y="{y}"/>' for x, y in points)
        at = f' x="{label_pos}"' if label_pos is not None else ""
        geo = (f'<mxGeometry{at} relative="1" as="geometry"><Array as="points">{pts}</Array></mxGeometry>' if pts
               else f'<mxGeometry{at} relative="1" as="geometry"/>')
        self.parts.append(f'<mxCell id={quoteattr(cid or self._id("e"))} value={quoteattr(label)} style={quoteattr(st)} edge="1" parent="1" '
                          f'source={quoteattr(src)} target={quoteattr(dst)}>{geo}</mxCell>')

    # ---- table
    def table(self, title, x, y, widths, header, rows, footer=None, cid=None):
        """Native draw.io table: 40px title, 40px per row, columns are multiples of 40. The page grows to fit the table."""
        _major(x=x, y=y, **{f"col{i}": w for i, w in enumerate(widths)})
        rh, w = G, sum(widths)
        h = rh + rh * (1 + len(rows) + (1 if footer else 0))
        self.h = max(self.h, -(-(y + h + rh) // rh) * rh)
        tid = self._cell(cid or self._id("tbl"), title, _TABLE, "1", f'x="{x}" y="{y}" width="{w}" height="{h}"')
        all_rows = [(header, True)] + [(r, False) for r in rows] + ([(footer, True)] if footer else [])
        for ri, (vals, bold) in enumerate(all_rows):
            rid = self._cell(self._id("r"), "", _TROW, tid, f'y="{rh + ri * rh}" width="{w}" height="{rh}"')
            cx = 0
            for ci, (v, cw) in enumerate(zip(vals, widths)):
                last = ci == len(widths) - 1
                align = "right" if last and (not bold or (footer and ri == len(all_rows) - 1)) else "left"
                st = _TCELL.format(fill="#F2F4F6" if bold else "none", align=align, bold="fontStyle=1;" if bold else "")
                self._cell(self._id("c"), str(v), st, rid, f'x="{cx}" width="{cw}" height="{rh}"')
                cx += cw
        return tid

    def xml(self, idx):
        return (f'<diagram id="p{idx}" name={quoteattr(self.name)}><mxGraphModel dx="1200" dy="800" grid="1" gridSize="{GRID}" guides="1" '
                f'tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="{self.w}" pageHeight="{self.h}" math="0" shadow="0">'
                '<root><mxCell id="0"/><mxCell id="1" parent="0"/>' + "".join(self.parts) + "</root></mxGraphModel></diagram>")


def write(pages: list[Page], out: Path, host="drawio_lib") -> Path:
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(f'<mxfile host="{host}" type="device">' + "".join(pg.xml(i) for i, pg in enumerate(pages, 1)) + "</mxfile>", encoding="utf8")
    return out


def drawio_cli() -> str:
    """The draw.io desktop CLI, first found of: $DRAWIO, `drawio` on PATH (Homebrew cask, Linux package), the macOS app."""
    for cand in (os.environ.get("DRAWIO"), shutil.which("drawio"), str(DRAWIO_APP)):
        if cand and Path(cand).is_file() and os.access(cand, os.X_OK):
            return cand
    raise RuntimeError(f"draw.io CLI not found: set DRAWIO, put `drawio` on PATH or install the app at {DRAWIO_APP}")


def export(drawio: Path, fmt="pdf", out: Path | None = None, page: int | None = None, scale=1) -> Path:
    """Export with the draw.io CLI. PDF: all pages, cropped to the drawing. PNG: one page (`page` is 1-based) — for visual inspection."""
    drawio = Path(drawio)
    out = Path(out) if out else drawio.with_suffix("." + fmt)
    cli = drawio_cli()
    out.unlink(missing_ok=True)   # a file left by an earlier run would hide a failed export
    cmd = [cli, "-x", "-f", fmt, "-o", str(out), str(drawio)]
    cmd[4:4] = ["--crop", "--all-pages"] if fmt == "pdf" else ["-s", str(scale)] + (["-p", str(page)] if page else [])
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if not out.exists():
        # A Homebrew wrapper on PATH can outlive the app it points to; its own error then names the missing path.
        raise RuntimeError(f"draw.io export failed ({cli}, exit {r.returncode}): " + (r.stdout + r.stderr)[-300:])
    return out
