#!/usr/bin/env python3
"""Ортогональная ER-схема: Graphviz раскладывает линии, знаки кратности рисуются отдельно."""

import math
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DOT = ROOT / "remkomstroy.dot"
SVG = ROOT / "remkomstroy.svg"

STROKE = "#334155"
WIDTH = "1.35"
KINDS = ("teetee", "odottee", "crowodot")


def parse_points(d):
    tokens = re.findall(r"[MLC]|-?\d+(?:\.\d+)?", d)
    points = []
    i = 0
    while i < len(tokens):
        op = tokens[i]
        if op in ("M", "L"):
            points.append((float(tokens[i + 1]), float(tokens[i + 2])))
            i += 3
        elif op == "C":
            i += 1
            while i + 5 < len(tokens) and tokens[i] not in "MLC":
                points.append((float(tokens[i + 4]), float(tokens[i + 5])))
                i += 6
        else:
            raise SystemExit(f"не понял команду пути: {op}")
    compact = [points[0]]
    for point in points[1:]:
        if math.hypot(point[0] - compact[-1][0], point[1] - compact[-1][1]) > 0.05:
            compact.append(point)
    return compact


def to_path(points):
    head = f"M{points[0][0]:.2f},{points[0][1]:.2f}"
    rest = "".join(f" L{x:.2f},{y:.2f}" for x, y in points[1:])
    return head + rest


def node_boxes(svg):
    boxes = {}
    pattern = re.compile(
        r'<g id="node\d+" class="node">\s*<title>([^<]+)</title>\s*<polygon[^>]*points="([^"]+)"'
    )
    for match in pattern.finditer(svg):
        coords = [
            (float(x), float(y))
            for x, y in re.findall(r"(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)", match.group(2))
        ]
        xs = [point[0] for point in coords]
        ys = [point[1] for point in coords]
        boxes[match.group(1)] = (min(xs), max(xs), min(ys), max(ys))
    return boxes


def inside(point, box, eps=1.0):
    minx, maxx, miny, maxy = box
    return minx + eps < point[0] < maxx - eps and miny + eps < point[1] < maxy - eps


def boundary_crossing(p, q, box):
    """Точка, где отрезок p→q пересекает рамку, ближайшая к p."""
    minx, maxx, miny, maxy = box
    x0, y0 = p
    x1, y1 = q
    dx, dy = x1 - x0, y1 - y0
    hits = []
    if abs(dx) > 1e-6:
        for x in (minx, maxx):
            t = (x - x0) / dx
            y = y0 + t * dy
            if 0 <= t <= 1 and miny - 0.2 <= y <= maxy + 0.2:
                hits.append((t, (x, y)))
    if abs(dy) > 1e-6:
        for y in (miny, maxy):
            t = (y - y0) / dy
            x = x0 + t * dx
            if 0 <= t <= 1 and minx - 0.2 <= x <= maxx + 0.2:
                hits.append((t, (x, y)))
    return hits


def clip_to_border(points, box, at_start):
    if at_start:
        if not inside(points[0], box):
            return points
        for i in range(len(points) - 1):
            hits = [hit for hit in boundary_crossing(points[i], points[i + 1], box) if hit[0] > 0.001]
            if hits:
                _, point = min(hits, key=lambda hit: hit[0])
                return [point] + points[i + 1 :]
    else:
        if not inside(points[-1], box):
            return points
        for i in range(len(points) - 2, -1, -1):
            hits = [hit for hit in boundary_crossing(points[i], points[i + 1], box) if hit[0] < 0.999]
            if hits:
                _, point = max(hits, key=lambda hit: hit[0])
                return points[: i + 1] + [point]
    return points


def merge_collinear(points):
    if len(points) < 3:
        return points
    merged = [points[0]]
    for index in range(1, len(points) - 1):
        ax, ay = merged[-1]
        bx, by = points[index]
        cx, cy = points[index + 1]
        cross = (bx - ax) * (cy - by) - (by - ay) * (cx - bx)
        if abs(cross) > 0.8:
            merged.append(points[index])
    merged.append(points[-1])
    return merged


def fit_scale(length, distance):
    return min(1.0, (length * 0.62) / distance)


def trim_start(points, distance):
    x0, y0 = points[0]
    x1, y1 = points[1]
    length = math.hypot(x1 - x0, y1 - y0) or 1.0
    scale = fit_scale(length, distance)
    distance *= scale
    ux, uy = (x1 - x0) / length, (y1 - y0) / length
    start = (x0 + ux * distance, y0 + uy * distance)
    return [start] + points[1:], (-ux, -uy), scale


def trim_end(points, distance):
    x0, y0 = points[-2]
    x1, y1 = points[-1]
    length = math.hypot(x1 - x0, y1 - y0) or 1.0
    scale = fit_scale(length, distance)
    distance *= scale
    ux, uy = (x1 - x0) / length, (y1 - y0) / length
    end = (x1 - ux * distance, y1 - uy * distance)
    return points[:-1] + [end], (ux, uy), scale


def depth_of(kind, scale):
    gap = 1.4 * scale
    if kind == "teetee":
        return gap + 5.6 * scale
    if kind == "odottee":
        return gap + 13.6 * scale
    if kind == "crowodot":
        return gap + 24.4 * scale
    raise SystemExit(kind)


def glyph(point, toward, kind, scale):
    ux, uy = toward
    px, py = -uy, ux
    gap = 1.4 * scale
    parts = []

    def at(along, side):
        return (
            point[0] - ux * along + px * side,
            point[1] - uy * along + py * side,
        )

    def line(a, b):
        parts.append(
            f'<path fill="none" stroke="{STROKE}" stroke-width="{WIDTH}" '
            f'stroke-linecap="round" d="M{a[0]:.2f},{a[1]:.2f} L{b[0]:.2f},{b[1]:.2f}"/>'
        )

    def circle(center, radius):
        parts.append(
            f'<circle fill="white" stroke="{STROKE}" stroke-width="{WIDTH}" '
            f'cx="{center[0]:.2f}" cy="{center[1]:.2f}" r="{radius:.2f}"/>'
        )

    bar = 8.0 * scale
    if kind == "teetee":
        for along in (gap + 0.7 * scale, gap + 4.4 * scale):
            line(at(along, -bar), at(along, bar))
    elif kind == "odottee":
        line(at(gap + 0.7 * scale, -bar), at(gap + 0.7 * scale, bar))
        radius = 4.2 * scale
        circle(at(gap + 3.6 * scale + radius, 0), radius)
    elif kind == "crowodot":
        foot = gap
        length = 14.0 * scale
        spread = 8.2 * scale
        joint = at(foot + length, 0)
        line(joint, at(foot, -spread))
        line(joint, at(foot, 0))
        line(joint, at(foot, spread))
        radius = 4.2 * scale
        circle(at(foot + length + 2.6 * scale + radius, 0), radius)
    return "".join(parts)


def border_point(box, side, t):
    x0, x1, y0, y1 = box
    if side == "n":
        return (x0 + (x1 - x0) * t, y0)
    if side == "s":
        return (x0 + (x1 - x0) * t, y1)
    if side == "w":
        return (x0, y0 + (y1 - y0) * t)
    if side == "e":
        return (x1, y0 + (y1 - y0) * t)
    raise SystemExit(side)


def route_between(tail, head, boxes):
    """Ломаная снаружи карточек: линия входит в рамку сущности, не в поле."""
    A = boxes[tail]
    B = boxes[head]
    left = min(box[0] for box in boxes.values()) - 46
    far_left = left - 22
    between_people = (boxes["contractor"][1] + boxes["spec"][0]) / 2 - 16
    beside_tender = boxes["tender"][1] + 28
    beside_place = boxes["facility"][1] + 34
    further = beside_place + 26
    furthest = further + 26

    pair = (tail, head)
    if pair == ("account", "contractor"):
        points = [border_point(A, "s", 0.5), border_point(B, "n", 0.5)]
    elif pair == ("account", "facility"):
        y = border_point(A, "e", 0.22)[1]
        points = [(A[1], y), (B[0], y)]
    elif pair == ("account", "project"):
        start = border_point(A, "w", 0.08)
        end = border_point(B, "w", 0.92)
        points = [start, (far_left, start[1]), (far_left, -605), (470, -605), (470, end[1]), end]
    elif pair == ("account", "defect"):
        start = border_point(A, "w", 0.92)
        end = border_point(B, "w", 0.92)
        points = [start, (left, start[1]), (left, end[1]), end]
    elif pair == ("contractor", "spec"):
        y = max(A[2], B[2]) + 22
        points = [(A[1], y), (B[0], y)]
    elif pair == ("contractor", "bid"):
        points = [border_point(A, "s", 0.5), border_point(B, "n", 0.5)]
    elif pair == ("contractor", "work"):
        start = border_point(A, "w", 0.92)
        end = border_point(B, "w", 0.72)
        points = [start, (left, start[1]), (left, -605), (beside_tender, -605), (beside_tender, end[1]), end]
    elif pair == ("facility", "element"):
        points = [border_point(A, "s", 0.5), border_point(B, "n", 0.5)]
    elif pair == ("facility", "project"):
        start = border_point(A, "e", 0.62)
        end = border_point(B, "e", 0.18)
        points = [start, (beside_place, start[1]), (beside_place, end[1]), end]
    elif pair == ("element", "element"):
        start = border_point(A, "e", 0.18)
        end = border_point(A, "e", 0.48)
        x = A[1] + 26
        points = [start, (x, start[1]), (x, end[1]), end]
    elif pair == ("element", "project"):
        points = [border_point(A, "s", 0.5), border_point(B, "n", 0.5)]
    elif pair == ("element", "work"):
        start = border_point(A, "e", 0.78)
        end = border_point(B, "e", 0.22)
        points = [start, (further, start[1]), (further, end[1]), end]
    elif pair == ("element", "defect"):
        start = border_point(A, "e", 0.92)
        end = border_point(B, "e", 0.35)
        points = [start, (furthest, start[1]), (furthest, end[1]), end]
    elif pair == ("spec", "work_type"):
        points = [border_point(A, "s", 0.5), border_point(B, "n", 0.5)]
    elif pair == ("spec", "tender"):
        start = border_point(A, "w", 0.92)
        end = border_point(B, "w", 0.08)
        points = [start, (between_people, start[1]), (between_people, end[1]), end]
    elif pair == ("work_type", "work"):
        start = border_point(A, "e", 0.78)
        end = border_point(B, "w", 0.08)
        points = [start, (beside_tender, start[1]), (beside_tender, end[1]), end]
    elif pair == ("project", "work"):
        points = [border_point(A, "s", 0.5), border_point(B, "n", 0.5)]
    elif pair == ("project", "tender"):
        start = border_point(A, "w", 0.78)
        end = border_point(B, "e", 0.22)
        x = boxes["tender"][1] + 52
        points = [start, (x, start[1]), (x, end[1]), end]
    elif pair == ("tender", "work"):
        y = max(A[2], B[2]) + 42
        points = [(A[1], y), (B[0], y)]
    elif pair == ("tender", "bid"):
        start = border_point(A, "w", 0.55)
        end = border_point(B, "e", 0.92)
        x = between_people - 8
        points = [start, (x, start[1]), (x, end[1]), end]
    elif pair == ("work", "work"):
        start = border_point(A, "e", 0.74)
        end = border_point(A, "e", 0.9)
        x = A[1] + 24
        points = [start, (x, start[1]), (x, end[1]), end]
    elif pair == ("work", "defect"):
        points = [border_point(A, "s", 0.5), border_point(B, "n", 0.5)]
    else:
        raise SystemExit(f"нет маршрута для {tail}->{head}")
    return merge_collinear(points)


def decorate(svg):
    boxes = node_boxes(svg)
    pattern = re.compile(
        r"<!-- (" + "|".join(KINDS) + r"),(" + "|".join(KINDS) + r") -->\s*"
        r'(<g id="edge\d+" class="edge">.*?</g>)',
        re.S,
    )

    def replace(match):
        tail_kind, head_kind, group = match.group(1), match.group(2), match.group(3)
        title = re.search(r"<title>([^<]+)</title>", group).group(1)
        title = title.replace("&#45;", "-").replace("&gt;", ">")
        tail_name, head_name = (part.split(":")[0] for part in title.split("->"))
        path_match = re.search(r'(<path\b[^>]*\sd=")([^"]+)(")', group)
        if not path_match:
            return match.group(0)
        points = route_between(tail_name, head_name, boxes)
        points, tail_dir, tail_scale = trim_start(points, depth_of(tail_kind, 1))
        points, head_dir, head_scale = trim_end(points, depth_of(head_kind, 1))
        tail_contact = (
            points[0][0] + tail_dir[0] * depth_of(tail_kind, tail_scale),
            points[0][1] + tail_dir[1] * depth_of(tail_kind, tail_scale),
        )
        head_contact = (
            points[-1][0] + head_dir[0] * depth_of(head_kind, head_scale),
            points[-1][1] + head_dir[1] * depth_of(head_kind, head_scale),
        )
        new_path = path_match.group(1) + to_path(points) + path_match.group(3)
        group = group[: path_match.start()] + new_path + group[path_match.end() :]
        marks = glyph(tail_contact, tail_dir, tail_kind, tail_scale) + glyph(
            head_contact, head_dir, head_kind, head_scale
        )
        group = group[:-4] + marks + "</g>"
        return f"<!-- {tail_kind},{head_kind} -->\n" + group

    updated, count = pattern.subn(replace, svg)
    if count != 22:
        raise SystemExit(f"ожидал 22 связи, обработал {count}")
    return updated


def main():
    raw = subprocess.check_output(["neato", "-n2", "-Tsvg", str(DOT)], text=True)
    SVG.write_text(decorate(raw), encoding="utf-8")
    print(SVG)


if __name__ == "__main__":
    sys.exit(main())
