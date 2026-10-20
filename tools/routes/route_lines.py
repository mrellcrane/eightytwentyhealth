"""Draw each researched route on the real path network, and each track as its mapped oval.

Routes: A* through the route's waypoints on every Overture segment near it (paths, sidewalks,
streets), preferring paths with the route's own name, then plain paths, then sidewalks,
then streets. The drawn line gives the length and, where OSM tags say, the surface mix.

Tracks: the OSM `leisure=track` outline closest to the researched center.
"""

import heapq
import json
import math
import os
import re
from collections import Counter, defaultdict

import pyarrow.parquet as pq
import shapely
from shapely.geometry import LineString, Point

from build_routes import PATHY, encode, meters

MILE = 1609.344
ROAD_COST = {
    "living_street": 1.3, "residential": 1.5, "service": 1.6, "unclassified": 1.6, "pedestrian": 1.1,
    "tertiary": 2.0, "secondary": 3.0, "primary": 4.0, "steps": 4.0, "unknown": 2.5,
}
SKIP_CLASSES = {"motorway", "trunk"}


def norm(name):
    return re.sub(r"[^a-z0-9]", "", (name or "").lower().replace("trail", "").replace("path", ""))


def name_matches(name, wanted):
    n = norm(name)
    return bool(n) and any(w and (w in n or n in w) for w in wanted)


def edge_surface(segment):
    """(surface, mapped) for any segment: paths from build_routes, sidewalks and streets from Overture."""
    kind = segment["kind"]
    if kind in PATHY and segment["row"]["subclass"] not in ("sidewalk", "crosswalk"):
        return segment["surface"], segment["mapped"]
    values = [s["value"] for s in segment["row"]["road_surface"] or []]
    if "gravel" in values:
        return "gravel", True
    if "dirt" in values or "unpaved" in values:
        return "dirt", "dirt" in values
    if segment["row"]["subclass"] in ("sidewalk", "crosswalk"):
        # Seattle-area sidewalks are concrete.
        return "concrete", False
    return "asphalt", False


_trees = {}


def segment_tree(segments):
    if id(segments) not in _trees:
        _trees[id(segments)] = shapely.STRtree([s["geom"] for s in segments])
    return _trees[id(segments)]


class Network:
    def __init__(self, segments, box, wanted_names, preferred_surfaces=()):
        self.adj = defaultdict(list)
        self.coord = {}
        self.named_nodes = set()
        for i in segment_tree(segments).query(shapely.box(*box)):
            s = segments[i]
            kind = s["kind"]
            if kind in SKIP_CLASSES or (s["row"]["subtype"] != "road"):
                continue
            named = name_matches(s["name"], wanted_names)
            if kind in PATHY and s["row"]["subclass"] not in ("sidewalk", "crosswalk"):
                cost = 1.0 if s.get("runnable", True) else 3.0
            elif s["row"]["subclass"] in ("sidewalk", "crosswalk"):
                cost = 1.25
            else:
                cost = ROAD_COST.get(kind, 2.0)
            if named:
                cost *= 0.35
            surface = edge_surface(s)
            # Where a soft path runs beside a paved one (Green Lake's outer loop), stay on the
            # surface the route is known for.
            if surface[0] in preferred_surfaces:
                cost *= 0.75
            # Extra vertices every ~40 m, so a waypoint snaps to the path beside it rather than
            # to the far end of a long straight piece (bridges, tunnels).
            coords = list(s["geom"].segmentize(0.0004).coords)
            for a, b in zip(coords, coords[1:]):
                ka, kb = self.key(a), self.key(b)
                length = meters(LineString([a, b]))
                self.adj[ka].append((kb, length, length * cost, surface))
                self.adj[kb].append((ka, length, length * cost, surface))
                if named:
                    self.named_nodes.update((ka, kb))

    def key(self, c):
        k = (round(c[0], 7), round(c[1], 7))
        self.coord[k] = c
        return k

    def nearest(self, lat, lon, prefer_named=True):
        best, best_d = None, float("inf")
        for k, (x, y) in self.coord.items():
            d = math.hypot((x - lon) * 75_000, (y - lat) * 111_195)
            if prefer_named and k in self.named_nodes:
                d -= 40  # snap to the route's own path when it's close
            if d < best_d:
                best, best_d = k, d
        return best, best_d

    def route(self, start, goal):
        """A* by cost; returns [(node, surface, length)] steps or None."""
        gx, gy = self.coord[goal]
        h = lambda k: math.hypot((self.coord[k][0] - gx) * 75_000, (self.coord[k][1] - gy) * 111_195) * 0.35
        frontier = [(h(start), 0.0, start)]
        came = {start: None}
        best = {start: 0.0}
        while frontier:
            _, cost, node = heapq.heappop(frontier)
            if node == goal:
                break
            if cost > best.get(node, float("inf")):
                continue
            for nxt, length, edge_cost, surface in self.adj[node]:
                c = cost + edge_cost
                if c < best.get(nxt, float("inf")):
                    best[nxt] = c
                    came[nxt] = (node, length, surface)
                    heapq.heappush(frontier, (c + h(nxt), c, nxt))
        if goal not in came:
            return None
        steps, node = [], goal
        while came[node] is not None:
            prev, length, surface = came[node]
            steps.append((node, surface, length))
            node = prev
        steps.append((start, None, 0.0))
        return list(reversed(steps))


def route_line(route, segments):
    waypoints = [tuple(w) for w in route.get("waypoints") or []]
    start = (route["start"]["lat"], route["start"]["lon"])
    if not waypoints:
        waypoints = [start]
    lats = [w[0] for w in waypoints] + [start[0]]
    lons = [w[1] for w in waypoints] + [start[1]]
    pad = 0.01
    box = (min(lons) - pad, min(lats) - pad, max(lons) + pad, max(lats) + pad)
    preferred = {k for k, v in route["surfaces"].items() if v >= 0.3}
    net = Network(segments, box, [norm(n) for n in route.get("pathNames") or [] if norm(n)], preferred)
    if route["kind"] == "loop" and len(waypoints) > 2 and math.dist(waypoints[0], waypoints[-1]) > 0.0005:
        waypoints = waypoints + [waypoints[0]]
    nodes, snaps = [], []
    for lat, lon in waypoints:
        node, d = net.nearest(lat, lon)
        nodes.append(node)
        snaps.append(round(d))
    coords, surface_m, mapped_m, total = [], Counter(), 0.0, 0.0
    for a, b in zip(nodes, nodes[1:]):
        if a == b:
            continue
        steps = net.route(a, b)
        if steps is None:
            return None, {"error": f"no path between waypoints {a} and {b}"}
        for node, surface, length in steps:
            if coords and coords[-1] == net.coord[node]:
                continue
            coords.append(net.coord[node])
            if surface:
                surface_m[surface[0]] += length
                mapped_m += length if surface[1] else 0
                total += length
    if len(coords) < 2:
        return None, {"error": "route collapsed to a point"}
    return LineString(coords), {"length": total, "surfaces": surface_m, "mapped": mapped_m / max(total, 1), "snaps": snaps}


def track_line(track, ovals):
    center = Point(track["start"]["lon"], track["start"]["lat"])
    best = min(ovals, key=lambda o: o.distance(center))
    if best.distance(center) * 100_000 > 80:
        return None
    ring = best.exterior if best.geom_type == "Polygon" else best
    return LineString(ring.coords)


def shares(counter):
    total = sum(counter.values())
    out = {k: v / total for k, v in counter.items() if v / total >= 0.02}
    t = sum(out.values())
    return {k: round(v / t, 2) for k, v in sorted(out.items(), key=lambda kv: -kv[1])}


def fix_sum(surfaces):
    """Rounded shares that add up to exactly 1."""
    s = {k: round(v, 2) for k, v in surfaces.items() if v > 0}
    top = max(s, key=s.get)
    s[top] = round(s[top] + 1 - sum(s.values()), 2)
    return s


def build(segments, data_dir, routes_path):
    with open(routes_path) as f:
        researched = json.load(f)
    land = pq.read_table(os.path.join(data_dir, "land_use.parquet")).to_pylist()
    ovals = [shapely.from_wkb(r["geometry"]) for r in land if r["class"] == "track"]

    out, problems = [], []
    for r in researched:
        miles = r["miles"]
        if r["kind"] == "track":
            line = track_line(r, ovals)
            if line is None:
                problems.append(f"{r['id']}: no mapped oval within 80 m")
                continue
            surfaces, length = r["surfaces"], miles * MILE
            check = f"oval {meters(line):.0f} m around"
        else:
            line, info = route_line(r, segments)
            if line is None:
                problems.append(f"{r['id']}: {info['error']}")
                continue
            drawn = info["length"]
            length = drawn * 2 if r["kind"] == "out-and-back" else drawn
            ratio = length / (miles * MILE)
            computed = shares(info["surfaces"])
            # OSM's own split where it tags nearly all of the drawn line (it's per-segment data and
            # matches the colored paths underneath); otherwise the researched split, which weighs
            # OSM against the trail's own pages. Big disagreements get a look.
            use_osm = info["mapped"] >= 0.8 and 0.85 <= ratio <= 1.15 and r.get("surfaceSource") != "research"
            surfaces = computed if use_osm else r["surfaces"]
            gap = sum(abs(computed.get(k, 0) - surfaces.get(k, 0)) for k in set(computed) | set(surfaces))
            computed_label = "OSM" if use_osm else "research"
            check = (f"[{computed_label}] drawn {length / MILE:.2f} mi vs researched {miles} (x{ratio:.2f}); snaps {info['snaps']} m; "
                     f"OSM surfaces ({info['mapped']:.0%} tagged) {computed} vs researched {r['surfaces']}")
            if not 0.6 <= ratio <= 1.6 or max(info["snaps"]) > 150 or (info["mapped"] >= 0.6 and gap > 0.6 and not use_osm):
                problems.append(f"{r['id']}: {check}")
            # Show the researched length (the published figure where there is one, the number
            # runners know); the drawn line is checked against it above.
            length = miles * MILE
        print(f"  {r['id']}: {check}")
        out.append({
            "id": r["id"], "name": r["name"], "area": r["area"], "kind": r["kind"], "meters": round(length),
            "surfaces": fix_sum(surfaces), "elevation": r.get("elevation", "flat"),
            "start": [round(r["start"]["lat"], 5), round(r["start"]["lon"], 5)],
            "startLabel": r["start"].get("label", ""), "notes": r["notes"], "access": r.get("access"),
            "lines": [encode(line.simplify(0.00002, preserve_topology=False).coords)],
        })
    print(f"{len(out)} routes; {len(problems)} to check:")
    for p in problems:
        print("  CHECK", p)
    return out

