"""Download the Seattle-area map data that build_routes.py turns into seattle-routes.json.

Both sources are public AWS buckets, read anonymously:
- Overture Maps (transportation segments; land use for tracks, parks and schools).
  OpenStreetMap-derived, with geometry, but its surface field only says "paved".
- The OpenStreetMap planet file as ORC (osm-pds), for each path's real `surface` tag
  (asphalt vs concrete, compacted vs dirt...). Only the stripes holding our way ids
  are read, a few GB, about 5 minutes.

    pip install pyarrow s3fs shapely
    python3 tools/routes/fetch_data.py DATA_DIR

Behind an HTTPS proxy, set HTTPS_PROXY and point REQUESTS_CA_BUNDLE at its CA.
"""

import bisect
import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.orc as orc
import pyarrow.parquet as pq
import s3fs

OVERTURE_RELEASE = "2026-09-23.1"
# South, north, west, east: Des Moines to Lynnwood's edge, Puget Sound to Issaquah.
S, N, W, E = 47.38, 47.85, -122.47, -121.95
# Tracks, and the parks and schools that name them and decide which paths count as park paths.
LAND_USE_CLASSES = ["track", "stadium", "school", "park", "nature_reserve", "state_park", "recreation_ground", "college", "university"]
PATHY = {"footway", "path", "track", "pedestrian", "cycleway", "bridleway"}
OSM_KEEP = {
    "highway", "surface", "footway", "name", "access", "foot", "tracktype", "smoothness", "sac_scale",
    "lit", "informal", "leisure", "sport", "bicycle", "indoor", "level", "bridge", "tunnel", "covered",
}


def filesystem(region):
    proxy = os.environ.get("HTTPS_PROXY")
    config = {"proxies": {"https": proxy}} if proxy else {}
    return s3fs.S3FileSystem(anon=True, client_kwargs={"region_name": region}, config_kwargs=config)


def overture(theme_type, columns, row_filter, out_path):
    """Rows of one Overture type inside the box, reading only row groups whose bbox stats overlap."""
    fs = filesystem("us-west-2")
    files = fs.ls(f"overturemaps-us-west-2/release/{OVERTURE_RELEASE}/{theme_type}/")
    first = pq.ParquetFile(files[0], filesystem=fs).metadata
    index = {first.schema.column(i).path: i for i in range(first.num_columns)}

    def overlapping(path):
        md = pq.ParquetFile(path, filesystem=fs).metadata
        hits = []
        for r in range(md.num_row_groups):
            stat = lambda p: md.row_group(r).column(index[p]).statistics
            if stat("bbox.xmin").min > E or stat("bbox.xmax").max < W or stat("bbox.ymin").min > N or stat("bbox.ymax").max < S:
                continue
            hits.append((path, r))
        return hits

    def read(job):
        path, r = job
        t = pq.ParquetFile(path, filesystem=fs).read_row_group(r, columns=columns)
        b = t.column("bbox")
        inside = pc.and_(
            pc.and_(pc.less_equal(pc.struct_field(b, "xmin"), E), pc.greater_equal(pc.struct_field(b, "xmax"), W)),
            pc.and_(pc.less_equal(pc.struct_field(b, "ymin"), N), pc.greater_equal(pc.struct_field(b, "ymax"), S)),
        )
        return t.filter(pc.and_(inside, row_filter(t)))

    with ThreadPoolExecutor(16) as ex:
        jobs = [j for hits in ex.map(overlapping, files) for j in hits]
    with ThreadPoolExecutor(8) as ex:
        table = pa.concat_tables(list(ex.map(read, jobs)))
    pq.write_table(table, out_path)
    print(f"{theme_type}: {table.num_rows} rows from {len(jobs)} row groups")
    return table


def osm_tags(way_ids, out_path):
    """OSM tags for these way ids, from the planet ORC (nodes, then ways, then relations, each by id)."""
    fs = filesystem("us-east-1")
    path = "osm-pds/planet/planet-latest.orc"
    stripes = orc.ORCFile(fs.open(path)).nstripes

    def open_file():
        return orc.ORCFile(fs.open(path, block_size=16 * 1024 * 1024))

    def first_type(i):
        return open_file().read_stripe(i, columns=["type"]).column("type")[0].as_py()

    # Binary search for where ways start and end.
    lo, hi = 0, stripes - 1
    while lo < hi:
        m = (lo + hi) // 2
        lo, hi = (m + 1, hi) if first_type(m) == "node" else (lo, m)
    first_way = max(lo - 1, 0)
    lo, hi = first_way, stripes - 1
    while lo < hi:
        m = (lo + hi) // 2
        lo, hi = (m + 1, hi) if first_type(m) != "relation" else (lo, m)
    last_way = lo

    def id_range(i):
        s = open_file().read_stripe(i, columns=["id", "type"])
        ids = pc.filter(s.column("id"), pc.equal(s.column("type"), "way"))
        return (i, pc.min(ids).as_py(), pc.max(ids).as_py()) if len(ids) else None

    with ThreadPoolExecutor(12) as ex:
        ranges = [r for r in ex.map(id_range, range(first_way, last_way + 1)) if r]
    starts = [r[1] for r in ranges]
    wanted = {}
    for way in way_ids:
        k = bisect.bisect_right(starts, way) - 1
        if k >= 0 and ranges[k][1] <= way <= ranges[k][2]:
            wanted.setdefault(ranges[k][0], []).append(way)

    def tags_in(stripe):
        want = pa.array(sorted(wanted[stripe]), pa.int64())
        for attempt in range(4):
            try:
                s = open_file().read_stripe(stripe, columns=["id", "type", "tags"])
                break
            except Exception:
                time.sleep(2 ** attempt)
        else:
            raise RuntimeError(f"stripe {stripe} failed 4 times")
        s = s.filter(pc.and_(pc.equal(s.column("type"), "way"), pc.is_in(s.column("id"), value_set=want)))
        return {i: {k: v for k, v in tags if k in OSM_KEEP} for i, tags in zip(s.column("id").to_pylist(), s.column("tags").to_pylist())}

    out = {}
    with ThreadPoolExecutor(12) as ex:
        for found in ex.map(tags_in, sorted(wanted)):
            out.update(found)
    with open(out_path, "w") as f:
        json.dump(out, f)
    print(f"OSM tags for {len(out)} of {len(way_ids)} ways from {len(wanted)} stripes")


def main(data_dir):
    os.makedirs(data_dir, exist_ok=True)
    segments = overture(
        "theme=transportation/type=segment",
        ["id", "names", "subtype", "class", "subclass", "road_surface", "sources", "geometry", "bbox", "level_rules", "access_restrictions"],
        lambda t: pc.equal(t.column("subtype"), "road"),
        os.path.join(data_dir, "segments.parquet"),
    )
    overture(
        "theme=base/type=land_use",
        ["id", "names", "subtype", "class", "surface", "source_tags", "geometry", "bbox"],
        lambda t: pc.is_in(t.column("class"), value_set=pa.array(LAND_USE_CLASSES)),
        os.path.join(data_dir, "land_use.parquet"),
    )
    way_ids = set()
    for row in segments.select(["class", "subclass", "sources"]).to_pylist():
        if row["class"] in PATHY and row["subclass"] not in ("sidewalk", "crosswalk", "cycle_crossing"):
            for source in row["sources"] or []:
                m = re.match(r"w(\d+)@", source["record_id"] or "")
                if m:
                    way_ids.add(int(m.group(1)))
    osm_tags(sorted(way_ids), os.path.join(data_dir, "osm_tags.json"))


if __name__ == "__main__":
    main(sys.argv[1])
