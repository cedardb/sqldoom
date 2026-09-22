#!/usr/bin/env python3
"""Draw the renderer statement's real query plan as an SVG.

Runs EXPLAIN (ANALYZE, FORMAT JSON) on sql/renderer.sql and lays the operator
tree out as a tidy tree: depth left to right, one row per leaf, node size and
edge weight from the *actual* row counts the engine measured, colour by
operator kind. Nothing here is illustrative -- every node and number is what
the server did for one frame.
"""
import argparse
import json
import math
import sys
from pathlib import Path

import psycopg2

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import doom_sql as sql  # noqa: E402

# Children hang off these keys, sometimes behind a wrapper object (a set
# operation's arguments are {columns, input} pairs), so the walk below looks
# for the nearest operator nodes rather than assuming a fixed shape.
OPERATOR_COLOURS = {
    "join": "#e0913a",
    "pipelinebreakerscan": "#4f7ea8",
    "tablescan": "#6fbf7a",
    "select": "#c05b6b",
    "map": "#8f7bc4",
    "groupby": "#d8c34a",
    "temp": "#5aa8a0",
    "generateseries": "#9ba24f",
    "setoperation": "#c77bb0",
    "sort": "#7a8ba0",
    "inlinetable": "#a08b6f",
    "window": "#5f9ec4",
    "earlyprobe": "#8a8f74",
    "assertsinglerow": "#9c6f8a",
}
DEFAULT_COLOUR = "#7b8079"
BG = "#0a0b09"
INK = "#d7d3c2"
DIM = "#7d7a6c"
ACCENT = "#75d38b"


def child_operators(node):
    """The operator nodes directly beneath `node`, whatever wraps them."""
    found = []

    def descend(value):
        if isinstance(value, dict):
            if "operatorId" in value and "operator" in value:
                found.append(value)
            else:
                for item in value.values():
                    descend(item)
        elif isinstance(value, list):
            for item in value:
                descend(item)

    for key, value in node.items():
        if key in ("input", "left", "right", "magic", "pipelineBreaker",
                   "arguments"):
            descend(value)
    return found


def build(node, depth=0):
    rows = node.get("analyzePlanCardinality")
    if rows is None:
        rows = node.get("cardinality") or 0
    return {
        "op": node.get("operator", "?"),
        "physical": node.get("physicalOperator", ""),
        "rows": int(rows),
        "depth": depth,
        "children": [build(child, depth + 1)
                     for child in child_operators(node)],
    }


def layout(tree, row_step, col_step):
    """Tidy tree: each leaf gets its own row, parents centre over children."""
    cursor = [0]

    def place(node):
        node["x"] = node["depth"] * col_step
        if node["children"]:
            for child in node["children"]:
                place(child)
            first, last = node["children"][0], node["children"][-1]
            node["y"] = (first["y"] + last["y"]) / 2.0
        else:
            node["y"] = cursor[0] * row_step
            cursor[0] += 1

    place(tree)
    return cursor[0]


def flatten(tree):
    out = []

    def walk(node):
        out.append(node)
        for child in node["children"]:
            walk(child)

    walk(tree)
    return out


def pick_labels(nodes, limit, line_height):
    """Busiest operators first, skipping any that would sit on another label."""
    chosen = []
    for node in sorted(nodes, key=lambda n: -n["rows"]):
        if len(chosen) >= limit:
            break
        if all(abs(node["y"] - other["y"]) >= line_height * 1.8
               or abs(node["x"] - other["x"]) >= line_height * 18
               for other in chosen):
            chosen.append(node)
    return chosen


def type_scale(width):
    """Poster type has to grow with the canvas or it vanishes on a 4000px SVG."""
    return max(1.0, width / 1100.0)


def svg(nodes, width, height, stats):
    ts = type_scale(width)
    peak = max((n["rows"] for n in nodes), default=1) or 1

    def weight(rows):
        # log scale: a 78k-row join must not be 78,000x the width of a 1-row one
        return 1.0 + 5.0 * math.log10(1 + rows) / math.log10(1 + peak)

    def radius(rows):
        return 3.0 + 9.0 * math.log10(1 + rows) / math.log10(1 + peak)

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="0 0 {width} {height}">',
        f'<rect width="{width}" height="{height}" fill="{BG}"/>',
        '<g fill="none" stroke-linecap="round">',
    ]
    for node in nodes:
        for child in node["children"]:
            mid = (node["x"] + child["x"]) / 2.0
            parts.append(
                f'<path d="M{child["x"]:.1f},{child["y"]:.1f} '
                f'C{mid:.1f},{child["y"]:.1f} {mid:.1f},{node["y"]:.1f} '
                f'{node["x"]:.1f},{node["y"]:.1f}" '
                f'stroke="{OPERATOR_COLOURS.get(child["op"], DEFAULT_COLOUR)}" '
                f'stroke-opacity="0.5" '
                f'stroke-width="{weight(child["rows"]):.2f}"/>'
            )
    parts.append("</g>")
    for node in nodes:
        colour = OPERATOR_COLOURS.get(node["op"], DEFAULT_COLOUR)
        parts.append(
            f'<circle cx="{node["x"]:.1f}" cy="{node["y"]:.1f}" '
            f'r="{radius(node["rows"]):.2f}" fill="{colour}" '
            f'fill-opacity="0.9"/>'
        )
    for node in pick_labels(nodes, 14, 13 * ts):
        parts.append(
            f'<text x="{node["x"] + radius(node["rows"]) + 5:.1f}" '
            f'y="{node["y"] + 4:.1f}" font-family="monospace" '
            f'font-size="{11 * ts:.0f}" fill="{INK}">{node["op"]} '
            f'<tspan fill="{DIM}">{node["rows"]:,}</tspan></text>'
        )
    y = round(34 * ts)
    parts.append(f'<text x="{26 * ts:.0f}" y="{y}" font-family="monospace" '
                 f'font-size="{24 * ts:.0f}" fill="{ACCENT}">'
                 f'QUERY PLAN, ONE FRAME</text>')
    for line in stats:
        y += round(20 * ts)
        parts.append(f'<text x="{26 * ts:.0f}" y="{y}" font-family="monospace" '
                     f'font-size="{14 * ts:.0f}" fill="{DIM}">{line}</text>')
    y += round(28 * ts)
    for op, colour in sorted(OPERATOR_COLOURS.items()):
        count = sum(1 for n in nodes if n["op"] == op)
        if not count:
            continue
        parts.append(f'<circle cx="{32 * ts:.0f}" cy="{y - 4 * ts:.0f}" '
                     f'r="{5 * ts:.0f}" fill="{colour}"/>')
        parts.append(f'<text x="{48 * ts:.0f}" y="{y}" font-family="monospace" '
                     f'font-size="{13 * ts:.0f}" fill="{INK}">{op} '
                     f'<tspan fill="{DIM}">x{count}</tspan></text>')
        y += round(19 * ts)
    parts.append("</svg>")
    return "\n".join(parts)


def render_png(nodes, width, height, stats, path, supersample=2):
    """Same layout via PIL, supersampled because PIL will not anti-alias."""
    from PIL import Image, ImageDraw, ImageFont

    scale = supersample
    ts = type_scale(width)
    peak = max((n["rows"] for n in nodes), default=1) or 1
    image = Image.new("RGB", (width * scale, height * scale), BG)
    draw = ImageDraw.Draw(image, "RGBA")

    def weight(rows):
        return 1.0 + 5.0 * math.log10(1 + rows) / math.log10(1 + peak)

    def radius(rows):
        return 3.0 + 9.0 * math.log10(1 + rows) / math.log10(1 + peak)

    def rgba(colour, alpha=255):
        colour = colour.lstrip("#")
        return tuple(int(colour[i:i + 2], 16) for i in (0, 2, 4)) + (alpha,)

    for node in nodes:
        for child in node["children"]:
            colour = rgba(OPERATOR_COLOURS.get(child["op"], DEFAULT_COLOUR), 128)
            x0, y0 = child["x"] * scale, child["y"] * scale
            x1, y1 = node["x"] * scale, node["y"] * scale
            mid = (x0 + x1) / 2.0
            points = []
            for step in range(13):
                t = step / 12.0
                u = 1 - t
                points.append((
                    u**3 * x0 + 3*u*u*t*mid + 3*u*t*t*mid + t**3 * x1,
                    u**3 * y0 + 3*u*u*t*y0 + 3*u*t*t*y1 + t**3 * y1,
                ))
            draw.line(points, fill=colour,
                      width=max(1, round(weight(child["rows"]) * scale)),
                      joint="curve")
    for node in nodes:
        r = radius(node["rows"]) * scale
        colour = rgba(OPERATOR_COLOURS.get(node["op"], DEFAULT_COLOUR), 235)
        draw.ellipse([node["x"] * scale - r, node["y"] * scale - r,
                      node["x"] * scale + r, node["y"] * scale + r],
                     fill=colour)

    def font(size):
        px = max(8, round(size * ts * scale))
        for name in ("DejaVuSansMono.ttf", "DejaVuSans.ttf"):
            try:
                return ImageFont.truetype(name, px)
            except OSError:
                continue
        return ImageFont.load_default()

    for node in pick_labels(nodes, 14, 13 * ts):
        draw.text(((node["x"] + radius(node["rows"]) + 5) * scale,
                   (node["y"] - 7 * ts) * scale),
                  f'{node["op"]} {node["rows"]:,}', font=font(11),
                  fill=rgba(INK))
    draw.text((26 * ts * scale, 14 * ts * scale), "QUERY PLAN, ONE FRAME",
              font=font(24), fill=rgba(ACCENT))
    y = 34 * ts
    for line in stats:
        y += 20 * ts
        draw.text((26 * ts * scale, (y - 12 * ts) * scale), line, font=font(14),
                  fill=rgba(DIM))
    y += 28 * ts
    for op, colour in sorted(OPERATOR_COLOURS.items()):
        count = sum(1 for n in nodes if n["op"] == op)
        if not count:
            continue
        draw.ellipse([27 * ts * scale, (y - 9 * ts) * scale,
                      (27 * ts + 10 * ts) * scale, (y + ts) * scale],
                     fill=rgba(colour))
        draw.text((48 * ts * scale, (y - 11 * ts) * scale), f"{op} x{count}",
                  font=font(13), fill=rgba(INK))
        y += 19 * ts
    image.resize((width, height), Image.LANCZOS).save(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--map", type=int, default=1)
    ap.add_argument("--player", type=int, default=0)
    ap.add_argument("--skill", type=int, default=2)
    ap.add_argument("--out", default="plan.svg")
    ap.add_argument("--row-step", type=float, default=13.0)
    ap.add_argument("--col-step", type=float, default=46.0)
    args = ap.parse_args()

    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    x, y, angle, z = sql.spawn_stage(
        cur, {"map_id": args.map, "player_thing_id": args.player})
    body = sql.load_sql("renderer.sql").rstrip().rstrip(";")
    for token, value in (("$1", str(args.map)), ("$2", str(args.player)),
                         ("$3", str(args.skill)), ("$4", repr(x)),
                         ("$5", repr(y)), ("$6", repr(z)), ("$7", repr(angle))):
        body = body.replace(token, value)
    cur.execute("EXPLAIN (ANALYZE, FORMAT JSON) " + body)
    plan = json.loads(cur.fetchone()[0])["plan"]

    tree = build(plan)
    rows = layout(tree, args.row_step, args.col_step)
    nodes = flatten(tree)
    depth = max(n["depth"] for n in nodes)
    total_rows = sum(n["rows"] for n in nodes)
    stats = [
        f"{len(nodes)} operators, {depth + 1} deep, "
        f"{len(set(n['op'] for n in nodes))} kinds",
        f"{total_rows:,} rows through the plan for this one frame",
        f"widest operator: {max(n['rows'] for n in nodes):,} rows",
        "node size and edge weight are measured rows (log scale)",
        "EXPLAIN (ANALYZE, FORMAT JSON) on sql/renderer.sql",
    ]
    ts = type_scale(round(260 + depth * args.col_step + 260))
    # Start the tree clear of the legend column on the left and the header
    # block on top, both of which grow with the type scale.
    header = (34 + len(stats) * 20 + 70) * ts
    legend = 360 * ts
    margin_left, margin_top = round(legend), round(max(150 * ts, header))
    width = round(margin_left + depth * args.col_step + 260)
    height = round(margin_top + rows * args.row_step + 60)
    for node in nodes:
        node["x"] += margin_left
        node["y"] += margin_top
    out = Path(args.out)
    out.write_text(svg(nodes, width, height, stats))
    png = out.with_suffix(".png")
    render_png(nodes, width, height, stats, png)
    print(f"{out}: {width}x{height}, {len(nodes)} operators, "
          f"{total_rows:,} rows total")
    print(f"{png}: same layout rasterised")


if __name__ == "__main__":
    main()
