# Run map data

Builds `Packages/EightyTwentyCore/Sources/EightyTwentyCore/Routes/seattle-routes.json`, the paths, routes and tracks on the run map (`RouteCatalog`).

```sh
pip install pyarrow s3fs shapely
python3 tools/routes/fetch_data.py /tmp/routes-data      # ~5 min, reads public AWS buckets
python3 tools/routes/build_routes.py /tmp/routes-data    # rewrites the JSON and prints a check per route
```

Then run the core tests (`RouteCatalogTests` checks the bundled file).

## Where it comes from

- **Paths**: every footpath, trail, bike path, forest road and bridleway from OpenStreetMap, via [Overture Maps](https://overturemaps.org) (geometry) and the OSM planet file on AWS (`osm-pds`, for each path's real `surface` tag; Overture only says "paved"). Sidewalks, crossings, indoor and private paths are left out, and so are unnamed paved walkways outside parks (courtyards, campuses, parking lots).
- **Surfaces**: OSM's tags fold into six (`SURFACES` in `build_routes.py`): asphalt, concrete (also pavers and brick), gravel (compacted, fine gravel), dirt (earth, ground, grass, bark, woodchips), boardwalk (wood), track (tartan, rubber). About 60% of the length is tagged. The rest is a guess from what most paths of the same kind, in or out of a park, are made of here, and is marked `mapped: 0` (drawn faded in the app, and the card says so).
- **Tracks**: every OSM `leisure=track` oval for running or athletics becomes a track route, with when the public can use it (`tracks_access.json`, researched per school district, college and parks department: open, outside school hours, limited, or not confirmed). Closed ones (varsity-only, private schools) are left out. The 17 tracks in `routes.json` have their own research.
- **Routes** (`routes.json`): researched in October 2026 from parks departments, trail sites and runners' write-ups, with sources per route. Each one is drawn by routing through its waypoints on the real path network, preferring paths with the route's own name (`route_lines.py`). Where OSM tags most of the drawn line, its surface mix comes from the map; otherwise from the research. 

Map data © OpenStreetMap contributors, ODbL. The app shows that credit on the map and in the route cards.
