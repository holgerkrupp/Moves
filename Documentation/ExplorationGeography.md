# Exploration geography data

`ExplorationCountryBoundaries.json` is a bundled, offline country-level
dataset used only for derived/debug attribution. It is not part of the Fog
canonical raster and it cannot change which cells are explored.

The source is Natural Earth admin-0 data as distributed by
[`datasets/geo-countries`](https://github.com/datasets/geo-countries), whose
repository documents the public-domain/Open Data Commons PDDL 1.0 terms. The
vendored dataset stores the source URL, a source version identifier, and the
country geometry after simplification for an application bundle. Review the
upstream terms and geometry whenever updating the file.

The current resolver:

- normalizes longitude using the same wrapping rule as `fogRasterV1`;
- rejects invalid coordinates and applies polygon bounding boxes first;
- handles polygon holes with a ray-casting point-in-ring test;
- clips candidate polygons against the canonical Web-Mercator cell footprint
  and assigns the cell to the largest covered area, with country ID as the
  deterministic tie-breaker;
- falls back to deterministic center sampling only when the bundled geometry
  has no positive clipped area (for example an incomplete/disputed source
  polygon).

This is intentionally an attribution utility, not a replacement geographic
grid. First-level administrative regions are provided separately in
`ExplorationAdministrativeBoundaries.json`, generated from Natural Earth
admin-1 geometry and simplified for the offline resolver. Region IDs use
`iso_3166_2` where the source provides one (for example `DE-BY`) and retain
the source country ID for grouping.

Both country and region attribution use the same projected polygon clipping
policy. The result is exact for the bundled polygon geometry in raster space;
disputed-territory policy and historical boundary changes remain explicit
dataset-policy questions before release-facing geographic statistics are
enabled.

The prepared day index stores only dated country presence and compact cell
counts. It is a derived navigation aid, not a second raster or a source of
truth; deleting/replacing a dated shard invalidates it for rebuild.

## Country grouping policy

`ExplorationGeopoliticalPolicy` is deliberately separate from both the raster
and the boundary files. It assigns a stable continent label and reports two
debug counts: country IDs treated as UN-member-coded entities, and IDs treated
as territories/dependencies/special or disputed broader entities. The policy
contains a conservative explicit exception set and treats unknown/non-ISO IDs
as broader entities. These labels are product presentation policy only; they
must not be used as a legal or historical sovereignty database.
