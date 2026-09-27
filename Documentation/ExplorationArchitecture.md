# Exploration architecture

Moves remains authoritative in SwiftData and CloudKit. Exploration is derived
in bounded background slices and stored outside the model store:

```text
Moves / Visits
    -> ExplorationWorkQueue (durable, leased day identifiers)
    -> MoveRouteGeometry / importedRouteData
    -> MVEXPLR1 source shards
    -> canonical 64x64 block cache
    -> render hierarchy, geography, statistics, passport, achievements,
       and DEBUG-only presentation snapshots
```

## Work scheduling

`ExplorationWorkQueue` is a file-backed actor queue. It coalesces work by day,
orders live work before synchronized/imported work and historical backlog, and
uses leases that automatically become retryable after cancellation, expiration,
process termination, or device restart. Import and recording paths enqueue only
compact day keys; they do not rasterize routes or write Exploration files on
their initiating actors.

The preparation worker claims at most one day per invocation by default. It
uses a dedicated `@ModelActor`, reads route geometry through
`MoveRouteGeometry`, increments shard revisions for replacement, and atomically
updates the local cache. Flight evidence remains a separate layer and is
excluded from standard coverage by default.

## Derived data

The merged block cache is disposable and rebuilt from source shards. It also
invalidates the compact statistics snapshot and affected render-hierarchy
tiles when a source shard changes. Render tiles are coarse summaries only; the
canonical leaf blocks remain the source for exact Fog import/export.

Statistics use latitude-aware spherical cell area over the Web Mercator cell
footprints. Country and first-level region attribution is derived from bundled
offline boundaries and never changes canonical cells. Manual travel evidence
is kept in a separate atomic JSON store with explicit status/provenance; it
can add a passport entry without pretending that a route was recorded.
Achievement state is also derived and persisted separately so unlock dates are
stable across rebuilds. All current presentation surfaces are DEBUG-only and
read prepared files/snapshots. Render hierarchy reads pass through a bounded
actor-owned decoded-tile cache; map presentation does not retain the entire
hierarchy in memory.

The derived country-presence index stores compact dated country/cell-count
entries for matching-day navigation. Normal preparation updates only the
affected dated source-shard entry; full rebuild remains available for schema or
boundary-dataset changes. It intentionally excludes undated Fog evidence rather
than inventing dates. The index contract also carries backward-compatible
Move/Visit/distance/status/provenance fields, which remain unknown until a
future shard revision supplies those facts.

The DEBUG reset action removes disposable shards, merged blocks, render data,
derived snapshots and queue/checkpoint state. It deliberately preserves manual
travel evidence, which is an explicit user-owned input rather than disposable
preparation output.

Explicitly classified flight Moves also have a DEBUG-only lazy ticket generator.
Its recipe is versioned and deterministic from the stable Move ID, date, and
known endpoint countries. The artifact is clearly a Moves keepsake and never
fabricates airline, airport, booking, passenger, or machine-readable boarding
pass data.

The synthetic shard benchmark in `MovesTests/ExplorationTests.swift` currently
encodes approximately 100,000 cells in 13,100 bytes, 1,000,000 cells in
127,721 bytes, and 10,000,000 cells in 1,272,359 bytes on the current codec.
These are uncompressed deterministic bitmap-shard sizes, not cloud-transfer
measurements.

## Synchronization boundary

Only source shards are candidates for future transport. The merged cache,
render hierarchy, statistics, decoded blocks, and presentation snapshots are
device-local and disposable. No cell, block, tile, render tile, or statistic is
stored as a SwiftData or CloudKit record.

Transport selection remains intentionally deferred until iCloud Drive and
private CloudKit/CKAsset benchmarks cover bootstrap, incremental replacement,
conflicts, cancellation, and Timeline contention.

## Geographic attribution

The debug layer includes vendored country-level and first-level Natural Earth
datasets in `Moves/ExplorationCountryBoundaries.json` and
`Moves/ExplorationAdministrativeBoundaries.json`. They are derived from
public-domain/PDDL Natural Earth distributions and record source metadata.
The resolver clips candidate administrative polygons against each canonical
Web-Mercator cell and assigns the largest covered area with deterministic ID
tie-breaking. A sample fallback exists only for incomplete/disputed source
geometry; it never changes raster identity.

Presentation projection is kept behind `ExplorationMapProjection`. The current
Web-Mercator adapter consumes geographic value types and is not part of shard
addressing. A future Equal Earth/Apple adapter can therefore reuse the same
Fog cell and render hierarchy identities without re-indexing history.

Source replacement is revision-aware. A higher revision replaces the complete
source contribution, including an intentional empty tombstone. Older revisions
are ignored, so delayed transport cannot resurrect deleted coverage; equal
revisions use the encoded shard bytes as a deterministic convergence tie-break.
Affected blocks are rebuilt locally rather than rebuilding the global raster.

Country IDs are additionally grouped by the explicit product policy in
`ExplorationGeopoliticalPolicy.swift`. The debug statistics distinguish UN
member-coded evidence from territories, dependencies, and other broader
entities. This is a display classification, not a claim about sovereignty or
historical borders.
