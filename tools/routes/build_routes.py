"""Build Packages/EightyTwentyCore/Sources/EightyTwentyCore/Routes/seattle-routes.json.

    python3 tools/routes/fetch_data.py DATA_DIR      # once; downloads OSM/Overture data
    python3 tools/routes/build_routes.py DATA_DIR    # writes the app's JSON and prints a check

Inputs: DATA_DIR from fetch_data.py, and tools/routes/routes.json (the researched routes
and tracks: names, surfaces, start points and waypoints, with sources).

Output, read by RouteCatalog.swift:
- trails: every runnable path (trails, bike paths, park paths, forest roads, not sidewalks),
  merged into long lines per surface and name, simplified to ~3 m, as encoded polylines.
- routes: each researched route, drawn by routing through its waypoints on the path
  network (preferring paths with the route's own name), and each running track's oval.
"""

import heapq
import json
import math
import os
import re
import sys
from collections import Counter, defaultdict

import pyarrow.parquet as pq
import shapely
from shapely.geometry import LineString, MultiLineString, Point

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "Packages", "EightyTwentyCore", "Sources", "EightyTwentyCore", "Routes", "seattle-routes.json")
ATTRIBUTION = "Map data © OpenStreetMap contributors (ODbL), via Overture Maps. Routes researched October 2026."

PATHY = {"footway", "path", "track", "pedestrian", "cycleway", "bridleway"}
PARKS = {"park", "nature_reserve", "state_park", "recreation_ground"}
SKIP_FOOTWAY = {"sidewalk", "crossing", "access_aisle", "traffic_island", "link"}

# OSM surface tag -> app surface. "paved"/"unpaved" and missing tags are guessed below.
SURFACES = {
    "asphalt": "asphalt", "chipseal": "asphalt", "tarmac": "asphalt",
    "concrete": "concrete", "concrete:plates": "concrete", "concrete:lanes": "concrete",
    "paving_stones": "concrete", "paving_stones:lanes": "concrete", "sett": "concrete", "bricks": "concrete",
    "brick": "concrete", "cobblestone": "concrete", "unhewn_cobblestone": "concrete", "stone": "concrete",
    "metal": "concrete", "metal_grid": "concrete", "grass_paver": "concrete",
    "compacted": "gravel", "fine_gravel": "gravel", "gravel": "gravel", "pebblestone": "gravel",
    "crushed_limestone": "gravel", "crushed_rock": "gravel",
    "dirt": "dirt", "earth": "dirt", "ground": "dirt", "grass": "dirt", "mud": "dirt", "sand": "dirt",
    "woodchips": "dirt", "clay": "dirt", "natural": "dirt", "rock": "dirt", "roots": "dirt", "bark": "dirt",
    "mulch": "dirt", "dirt/sand": "dirt",
    "wood": "boardwalk", "boardwalk": "boardwalk", "decking": "boardwalk", "plastic": "boardwalk", "composite": "boardwalk",
    "tartan": "track", "rubber": "track", "acrylic": "track",
}
OVERTURE_SURFACES = {"paved": "paved", "paving_stones": "concrete", "gravel": "gravel", "dirt": "dirt", "unpaved": "unpaved", "metal": "concrete"}


def osm_way_id(row):
    for source in row["sources"] or []:
        m = re.match(r"w(\d+)@", source.get("record_id") or "")
        if m:
            return m.group(1)
    return None


def first_value(tag):
    return (tag or "").split(";")[0].strip().lower() or None


def raw_surface(row, tags):
    """(surface or 'paved'/'unpaved'/None, whether OSM said exactly)."""
    tagged = first_value(tags.get("surface"))
    if tagged in SURFACES:
        return SURFACES[tagged], True
    if tagged in ("paved", "unpaved"):
        return tagged, False
    values = [s["value"] for s in row["road_surface"] or [] if s.get("value") in OVERTURE_SURFACES]
    if values:
        value = Counter(values).most_common(1)[0][0]
        mapped = OVERTURE_SURFACES[value]
        return mapped, mapped in ("gravel", "dirt", "concrete") and value != "metal"
    return None, False


def guess(kind, in_park, generic, majority):
    """Best guess when OSM says only paved/unpaved, or nothing: what most paths of the
    same kind, in the same setting (park or not), are made of here when OSM does say."""
    among = {"paved": ("asphalt", "concrete"), "unpaved": ("gravel", "dirt")}.get(generic, tuple(set(SURFACES.values())))
    for key in ((kind, in_park), (kind, not in_park)):
        counts = [(n, s) for s, n in majority[key].items() if s in among]
        if counts:
            return max(counts)[1]
    return among[0]


def runnable(segment):
    row, tags = segment["row"], segment["tags"]
    if row["class"] not in PATHY or row["subclass"] in ("sidewalk", "crosswalk", "cycle_crossing"):
        return False
    if tags.get("footway") in SKIP_FOOTWAY or tags.get("highway") in ("steps", "corridor", "elevator"):
        return False
    if tags.get("indoor") == "yes" or (tags.get("level") or "0").split(";")[0] not in ("0", ""):
        return False
    foot = tags.get("foot")
    if foot in ("no", "private"):
        return False
    if tags.get("access") in ("private", "no") and foot not in ("yes", "designated", "permissive"):
        return False
    if any(r.get("access_type") == "denied" and not (r.get("when") or {}).get("mode") for r in row["access_restrictions"] or []):
        return False
    # Unnamed paved walkways outside parks are courtyards, campuses and parking lots,
    # not places to run; they'd bury the map in purple.
    if row["class"] in ("footway", "pedestrian") and not segment["in_park"] and segment["name"] is None \
            and segment["surface"] in ("asphalt", "concrete"):
        return False
    return True


def encode(coords):
    """Google encoded polyline, precision 1e-5; coords are (lon, lat)."""
    out, prev_lat, prev_lon = [], 0, 0
    for lon, lat in coords:
        lat_i, lon_i = round(lat * 1e5), round(lon * 1e5)
        for value in (lat_i - prev_lat, lon_i - prev_lon):
            v = ~(value << 1) if value < 0 else value << 1
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        prev_lat, prev_lon = lat_i, lon_i
    return "".join(out)


def meters(line):
    coords = list(line.coords)
    total = 0.0
    for (x1, y1), (x2, y2) in zip(coords, coords[1:]):
        dy = (y2 - y1) * 111_195
        dx = (x2 - x1) * 111_195 * math.cos(math.radians((y1 + y2) / 2))
        total += math.hypot(dx, dy)
    return total


def simplified(line):
    s = line.simplify(0.00003, preserve_topology=False)
    return s if not s.is_empty and len(s.coords) >= 2 else line


def lines_of(geom):
    if geom.is_empty:
        return []
    if isinstance(geom, LineString):
        return [geom]
    return [g for g in getattr(geom, "geoms", []) if isinstance(g, LineString)]


# MARK: Trails


def park_shapes(data_dir):
    rows = pq.read_table(os.path.join(data_dir, "land_use.parquet")).to_pylist()
    return [shapely.from_wkb(r["geometry"]) for r in rows if r["class"] in PARKS]


def classify_segments(data_dir):
    rows = pq.read_table(os.path.join(data_dir, "segments.parquet")).to_pylist()
    with open(os.path.join(data_dir, "osm_tags.json")) as f:
        osm = json.load(f)
    geoms = [shapely.from_wkb(r["geometry"]) for r in rows]
    parks = shapely.STRtree(park_shapes(data_dir))
    in_park = set(parks.query(geoms, predicate="intersects")[0].tolist())

    segments = []
    for i, row in enumerate(rows):
        tags = osm.get(osm_way_id(row) or "", {})
        surface, exact = raw_surface(row, tags)
        segments.append({
            "row": row, "tags": tags, "geom": geoms[i], "name": (row["names"] or {}).get("primary"),
            "kind": row["class"], "in_park": i in in_park,
            "surface": surface, "mapped": exact and surface in SURFACES.values(),
        })

    # What each kind of path, in or out of parks, is made of when OSM says, by length.
    majority = defaultdict(Counter)
    for s in segments:
        if s["mapped"] and s["row"]["subclass"] not in ("sidewalk", "crosswalk", "cycle_crossing") \
                and s["tags"].get("footway") not in SKIP_FOOTWAY:
            majority[(s["kind"], s["in_park"])][s["surface"]] += meters(s["geom"])
    for s in segments:
        if not s["mapped"]:
            s["surface"] = guess(s["kind"], s["in_park"], s["surface"], majority)
        s["runnable"] = runnable(s)
    return segments


def build_trails(segments):
    groups = defaultdict(list)
    for s in segments:
        if s["runnable"]:
            groups[(s["surface"], s["mapped"], s["name"])].append(s["geom"])
    trails = []
    for (surface, mapped, name), geoms in groups.items():
        merged = shapely.line_merge(shapely.union_all(geoms)) if len(geoms) > 1 else geoms[0]
        for line in lines_of(merged):
            length = meters(line)
            # Unnamed stubs (building entrances, plaza bits) are noise on a run map.
            if name is None and length < 60:
                continue
            trails.append([surface, 1 if mapped else 0, name, encode(simplified(line).coords), length])
    trails.sort(key=lambda t: (t[0], t[2] or "", -t[4]))
    return trails


def track_ovals(data_dir):
    """Running tracks mapped in OSM (`leisure=track`), named after their school or park."""
    rows = pq.read_table(os.path.join(data_dir, "land_use.parquet")).to_pylist()
    owners = [(shapely.from_wkb(r["geometry"]), (r["names"] or {}).get("primary"))
              for r in rows if r["class"] in ("school", "park", "stadium", "college", "university", "recreation_ground")]
    owners = [(g, n) for g, n in owners if n]
    tree = shapely.STRtree([g for g, _ in owners])
    out = []
    for r in rows:
        tags = dict(r["source_tags"] or [])
        if r["class"] != "track" or tags.get("sport") not in (None, "running", "athletics", "multi"):
            continue
        if tags.get("access") in ("private", "no"):
            continue
        geom = shapely.from_wkb(r["geometry"])
        ring = LineString(geom.exterior.coords) if geom.geom_type == "Polygon" else geom
        if not isinstance(ring, LineString) or not 250 <= meters(ring) <= 700:
            continue  # bike pump tracks and horse rings
        surface = SURFACES.get(first_value(tags.get("surface")))
        holders = [owners[i][1] for i in tree.query(geom.centroid, predicate="intersects")]
        name = (r["names"] or {}).get("primary") or (f"{holders[0]} track" if holders else "Running track")
        out.append([surface or "track", 1 if surface else 0, name, encode(simplified(ring).coords), meters(ring)])
    return out


def main(data_dir):
    segments = classify_segments(data_dir)
    routes = []
    routes_path = os.path.join(HERE, "routes.json")
    if os.path.exists(routes_path):
        import route_lines
        routes = route_lines.build(segments, data_dir, routes_path)
    trails = build_trails(segments) + track_ovals(data_dir)
    by_surface = Counter()
    for t in trails:
        by_surface[t[0]] += t[4]
    print(f"{len(trails)} trail lines, {sum(by_surface.values()) / 1609.344:.0f} mi:",
          {k: f"{v / 1609.344:.0f} mi" for k, v in by_surface.most_common()})
    mapped = sum(t[4] for t in trails if t[1]) / max(1, sum(by_surface.values()))
    print(f"surface tagged in OSM for {mapped:.0%} of the length")

    doc = {"attribution": ATTRIBUTION, "trails": [t[:4] for t in trails], "routes": routes}
    with open(OUT, "w") as f:
        json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
    print(f"wrote {os.path.relpath(OUT)}: {os.path.getsize(OUT) / 1e6:.1f} MB")


if __name__ == "__main__":
    sys.path.insert(0, HERE)
    main(sys.argv[1])
