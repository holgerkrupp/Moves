# Fog of the World FWSS / sync format notes

Status: **reverse-engineering notes, verified against the user-supplied 2026-09-20 snapshot and four supplied sync tile files**.

This document exists to support Moves issue #53 and the later importer in #54. It describes compatibility observations only. Fog of the World is not affiliated with Moves.

> Privacy: the complete supplied snapshot contains private location coverage and is deliberately **not** committed. This document records structure and aggregate facts only; it does not list the user's visited coordinates.

## Executive summary

The supplied `.fwss` is a ZIP container. Its useful exploration state is a set of Web-Mercator bitmap tiles under `Model/*/`. Each bitmap tile is independently zlib/DEFLATE-compressed. The base world grid is 512 x 512 tiles (Web-Mercator zoom 9). Each base tile contains a sparse 128 x 128 block grid; each present block contains a 64 x 64 one-bit visited bitmap plus three bytes of auxiliary data. Therefore the complete world raster is 512 * 128 * 64 = 4,194,304 pixels wide (`2^22`). One pixel is about 9.55 m at the equator and scales by `cos(latitude)` on the ground.

The supplied standalone sync files are the same zlib-compressed **base bitmap tile** representation used by `Model/*/`. Two of the supplied sync files are byte-for-byte identical to the corresponding tiles in the full snapshot; two are newer revisions of tiles with the same filenames. This strongly supports treating sync tile files as independently mergeable replacements/updates keyed by tile ID, with exploration merge semantics being a bitmap union for a one-way migration.

No timestamps, route ordering, trip identity, transport mode, or visit history are present in the decoded base bitmap representation. The format is sufficient to recover **revealed geography**, not Moves timeline history. Production import must not synthesize dates/routes/trips from FWSS coverage.

An independent open-source compatibility implementation, `CaviarChen/fog-machine`, documents and implements the same tile encoding and was used as a cross-check. Relevant files are `editor/src/utils/FowTile.ts`, `FwssArchive.ts`, `FowSyncArchive.ts`, and `FogMap.ts`.

## Supplied fixture observations

Full snapshot: `Snapshot-20260920T122032+0200.fwss` (private fixture; do not commit).

Observed container contents:

| Path family | Count | Meaning / confidence |
| --- | ---: | --- |
| `Model/*/<name>` | 1,141 | Base zoom-9 visited bitmap tiles. **High confidence.** |
| `Model/#/<name>` | 1,143 | Hash/count sidecars plus snapshot metadata/index. Not required to recover geography. **High confidence for role; individual fields partly inferred.** |
| `Model/~/<name>` | 1,274 | Downsampled overview/layer tiles for lower zoom rendering. Derived from base bitmap tiles. **High confidence.** |
| `Caches/f42b7522/<name>` | 26 | Four-byte values (`01 00 00 00` in this fixture). Purpose is not required for exploration import and remains intentionally unspecified. |

Total ZIP entries in this fixture: 3,584.

The ZIP itself uses ordinary ZIP entries. The payloads under `Model/*`, `Model/#`, and `Model/~` are generally zlib streams even when the ZIP layer also applies compression. Import code should therefore treat container compression and record compression as separate layers.

## Base tile filename encoding (`Model/*` and sync tiles)

A base tile filename encodes a numeric tile ID.

Digit mask:

```text
0123456789 -> olhwjsktri
```

For a filename such as `<4 hex chars><masked decimal id><2 checksum chars>`:

1. Ignore the first four characters for ID decoding.
2. Ignore the last two characters for ID decoding.
3. Map each middle character through `olhwjsktri` back to decimal digits.
4. Parse the result as a decimal integer `id`.
5. `x = id % 512`
6. `y = id / 512` (integer division)

The leading four characters are derived from an MD5 checksum input and the final two characters are a second masked checksum. They should be validated by a production parser rather than trusted solely as an ID carrier. The exact generation rules are implemented in the upstream compatibility implementation and differ slightly by snapshot file type/layer.

For the supplied four standalone sync files, decoding produces four adjacent zoom-9 tiles. All four filenames also occur under `Model/*/` in the full FWSS snapshot.

## Geographic projection

The tile grid uses standard spherical Web Mercator / slippy-map equations at zoom 9.

For base-tile coordinate `(x, y)`:

```text
longitude = x / 512 * 360 - 180
latitude  = atan(sinh(pi - 2*pi*y/512)) * 180/pi
```

The inverse is:

```text
x = (longitude + 180) / 360 * 512
y = (pi - asinh(tan(latitude*pi/180))) * 512 / (2*pi)
```

Within each base tile there are 128 x 128 blocks, and each block is 64 x 64 pixels. The global exploration raster is consequently `2^22 x 2^22` pixels.

Approximate pixel ground size:

```text
40075016.686 m / 2^22 ~= 9.5546 m at the equator
pixelGroundSize(latitude) ~= 9.5546 * cos(latitude) m
```

This is close to Moves' planned ~10 m canonical exploration resolution, but Fog's raster must remain an **input adapter**, not Moves' persistent canonical grid.

## Base bitmap tile payload

After zlib inflation, a base tile consists of:

```text
+-------------------------------+
| 128*128 UInt16 block indexes  | 32768 bytes
+-------------------------------+
| block payload #1              | 515 bytes
+-------------------------------+
| block payload #2              | 515 bytes
+-------------------------------+
| ...                           |
+-------------------------------+
```

### Header

The header is 16,384 little-endian `UInt16` values, one for each block position in row-major order.

- `0` = block absent / no revealed pixels in that block.
- `n > 0` = payload is block record `n`, where records are stored after the 32,768-byte header.
- Block coordinate: `blockX = index % 128`, `blockY = index / 128`.

### Block payload

Each base block is 515 bytes:

- bytes `0..<512`: 64 x 64 one-bit visited bitmap.
- bytes `512..<515`: three bytes of auxiliary/check/count information.

Bitmap addressing is row-major. Each row occupies eight bytes. For pixel `(x, y)` inside a 64 x 64 block:

```text
byteIndex = floor(x / 8) + y * 8
bit        = 7 - (x % 8)
visited    = bitmap[byteIndex] & (1 << bit) != 0
```

Thus X increases east/right, Y increases south/down, and bits within a byte run most-significant-bit to least-significant-bit from left to right.

The low 14 bits of the final two auxiliary bytes encode `(visitedPixelCount * 2 + 1)` in big-endian form in observed/compatible files; this provides a useful integrity check. Some implementations also decode region-like information from the auxiliary bits, but Moves does not need this to recover geography and should not assign product semantics to it without separate validation.

## Converting a visited bit to geography

Given base tile `(tileX, tileY)`, block `(blockX, blockY)`, and pixel `(pixelX, pixelY)`:

```text
globalX = tileX * 8192 + blockX * 64 + pixelX
globalY = tileY * 8192 + blockY * 64 + pixelY
N       = 2^22

longitude = globalX / N * 360 - 180
latitude  = atan(sinh(pi - 2*pi*globalY/N)) * 180/pi
```

For cell bounds, transform both `(globalX, globalY)` and `(globalX + 1, globalY + 1)`; do not treat the pixel center as its full geographic extent.

## `Model/#`: hash/count records, metadata and tile index

The snapshot contains two known special records under `Model/#`:

- `3389dae361`: zlib-compressed 32,768-byte bitset (`512*512/8`) indicating which base tiles are present. In the supplied fixture it inflates to exactly 32,768 bytes.
- `01abfc750a`: zlib-compressed 4,012-byte snapshot metadata record. In the supplied fixture it inflates to exactly 4,012 bytes.

Other `Model/#` files correspond to base tiles and contain compact per-block hash/count payloads. They are useful for Fog's own snapshot machinery but are **not needed to recover the authoritative revealed bitmap** for Moves.

The open-source compatibility implementation derives these records from the base bitmap, which is further evidence that Moves should import `Model/*` as the geographic source of truth and treat `#` data as optional validation/metadata.

## `Model/~`: lower-resolution derived layers

`Model/~` contains downsampled bitmap layers used for lower zoom levels. The compatibility implementation constructs them recursively from zoom-9 base tiles down through lower layers. Each parent pixel is effectively revealed when any source pixels in its corresponding 2 x 2 area are revealed.

These layers are **derived** and should not be imported into Moves' canonical exploration data. Ignoring them avoids double counting and simplifies version compatibility.

## Sync files

Fog's sync representation uses the same tile format as the `Model/*` base bitmap tiles. A sync ZIP, when present, conventionally contains these files under `Sync/`, but individual tile files can also be decoded directly.

Comparison of the four supplied standalone sync tile fixtures with the full snapshot:

- all four filenames map to valid base tile IDs and are present in `Model/*`;
- two are byte-for-byte identical to the corresponding full-snapshot tile;
- two have the same tile identity but contain later bitmap revisions / additional data;
- the changed files remain valid zlib streams and decode using the same 32,768-byte sparse-block header + 515-byte block representation.

### Import semantics recommendation

For a one-way migration into Moves:

1. Decode each sync tile independently.
2. Convert visited bits to Moves canonical exploration cells.
3. Union imported coverage with existing Moves/imported coverage.
4. Never clear a Moves cell merely because an older sync tile has an unset bit.
5. Re-import must be idempotent.

This makes standalone sync tiles useful as incremental **positive exploration evidence** without requiring Moves to reproduce Fog's bidirectional sync semantics.

## Information that can be recovered

### Recoverable with high confidence

- revealed/unrevealed geographic coverage;
- zoom-9 tile identity and bounds;
- individual ~Web-Mercator zoom-22 raster cells;
- aggregate revealed pixel counts (and therefore approximate area);
- presence of base tiles;
- incremental additional coverage from supplied sync tile revisions.

### Not present in the decoded exploration bitmap

Do **not** infer or synthesize:

- timestamps or first-visited dates;
- ordered GPS tracks;
- trips/journeys;
- visits/stays;
- speed or transport mode;
- duration at a location;
- passport arrival dates.

The FWSS may contain metadata useful to Fog itself, but the decoded base exploration records do not provide those timeline semantics. Issue #54 should therefore import Fog as undated geographic exploration evidence only.

## Version detection and safe failure

The supplied FWSS does not expose a simple human-readable format-version manifest at the ZIP root. Production support should consequently be **structural/version-aware**, not based only on the `.fwss` extension.

Before modifying Moves exploration state, require all of the following for this supported format generation:

1. Valid ZIP container.
2. At least one `Model/*/<filename>` candidate.
3. Filename decodes and checksum validates according to the known scheme.
4. zlib inflation succeeds.
5. Inflated payload is at least 32,768 bytes.
6. Every non-zero header block index resolves to a complete 515-byte block payload within bounds.
7. Block count/check data is internally consistent where available.
8. Tile coordinates remain inside `0..<512`.

Optional cross-checks:

- if `Model/#/3389dae361` exists, its inflated size must be 32,768 bytes and its bitset should agree with decoded base tile presence;
- recognize `Model/#/01abfc750a` as metadata, but do not make geography import depend on understanding every metadata field;
- ignore unknown `Caches/*` records and unknown derived records unless a future format adapter explicitly supports them.

If these invariants fail, abort before committing imported coverage and report an unsupported/changed Fog snapshot format. Do not attempt heuristic parsing of malformed records in production.

## Suggested adapter boundary for Moves

Keep this format isolated, for example:

```text
FogOfWorldSnapshotAdapter
  inspect(url) -> format/version/capabilities
  streamBaseTiles(url) -> AsyncSequence<FogTile>
  decode(tile) -> visited geographic cells

FogOfWorldSyncTileAdapter
  inspect(data/URL)
  decode(tile) -> visited geographic cells
```

The adapter should emit geography/evidence into the Exploration importer. It must not expose Fog tile IDs as Moves' persistent model identity.

## Testing recommendations

Safe repository fixtures can be generated rather than copying private tiles:

- empty/minimal valid tile;
- one bit at each corner of a block;
- bits crossing byte, block, tile, and Web-Mercator boundaries;
- several synthetic tiles at widely separated latitudes;
- malformed zlib stream;
- invalid block index / truncated payload;
- invalid filename/checksum;
- unsupported ZIP structure;
- old/new sync versions whose union is deterministic.

A coordinate test should generate a synthetic Fog tile from known public coordinates, decode it, and assert that the resulting cell bounds contain the source coordinate. This avoids committing any user location history.

## Remaining unknowns / follow-up

- Exact product semantics of `Caches/f42b7522/*` are unknown and unnecessary for migration.
- Not every field of the 4,012-byte metadata record has been independently verified. Known compatibility code can generate it, but Moves should not depend on undocumented fields.
- The filename checksum should be implemented and tested in the Moves adapter, not merely the middle-ID decoder described above.
- Before closing #53, add synthetic decoder/probe tests in Moves (or a developer utility target) and validate the geographic transform with synthetic known coordinates. This is preferable to publishing coordinates from the private supplied snapshot.

## External cross-check

The independent open-source project **Fog Machine** implements Fog of the World compatibility and matches the observed fixture structure:

- `CaviarChen/fog-machine/editor/src/utils/FowTile.ts` — filename decoding, zlib tile decoding, block layout, bitmap orientation, Web-Mercator transform.
- `.../FwssArchive.ts` — FWSS ZIP structure, base/hash/layer generation, metadata and tile-index constants.
- `.../FowSyncArchive.ts` — `Sync/` archive semantics using base tile payloads.
- `.../FogMap.ts` — global coordinate raster (`512 * 128 * 64`) and tile loading.

These sources are used as interoperability evidence; no Fog/Fog Machine code should be copied into production without reviewing its license and reimplementing only the required format concepts in Moves' own architecture.
