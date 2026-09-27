# Fog of World compatibility

This document records the Phase A interoperability boundary. Moves Exploration
uses the Fog leaf raster as its canonical geometry, but its replaceable source
shards and device-local cache are not Fog's native files.

## Sources inspected

- CaviarChen/fog-machine, especially `editor/src/utils/FowTile.ts`,
  `FogMap.ts`, `FowSyncArchive.ts`, `FwssArchive.ts`, and the round-trip/archive
  tests under `editor/src/__tests__`.
- CaviarChen/Fog-of-World-Data-Parser, especially `parser.py`.
- Relevant functions include `FogMap.LngLatToGlobalXY`,
  `Tile.LngLatToXY`, `Tile.create`, `Tile.dump`, `Block.isVisited`,
  `Block.setPoint`, `Block.dump`, `fowBitmapBlockExtraData`,
  `serializeBlocks`, and the `importFowSync`/`exportFowSync` and
  `importFwss`/`exportFwss` archive paths.
- Moves issues #29, #30, #31, #32, #33, #34, #35, #42, #51, #53, #56, #57,
  #60, and #63.

The repository now contains `Packages/FogOfWorldKit`, a small standalone native
archive boundary. It intentionally exposes canonical bitmap blocks and keeps
ZIP, zlib, sparse tile headers, filename obfuscation, and native trailer
validation out of the rest of Moves. It does not claim to preserve or recreate
all FWSS metadata and hierarchy records. Its container summary reports bitmap,
metadata, hierarchy, hash and other-entry counts so callers can distinguish a
bitmap conversion from a full FWSS metadata round trip.

## Confirmed canonical raster

Fog Machine independently demonstrates:

- Web Mercator world coordinates at base zoom 9;
- 512 x 512 base tiles globally;
- 128 x 128 blocks in each base tile;
- 64 x 64 leaf cells in each block;
- 8192 x 8192 leaf cells per base tile;
- a 2^22 x 2^22 global leaf raster.

For longitude `lon` and latitude `lat`, after clamping latitude to
`[-85.0511287798066, 85.0511287798066]` and wrapping longitude to
`[-180, 180)`, Moves computes:

```text
x = floor(((lon + 180) / 360) * 2^22)
y = floor((pi - asinh(tan(lat * pi / 180))) / (2 * pi) * 2^22)
```

Both coordinates are clamped to `[0, 2^22 - 1]`. The tile, block, and local
cell are integer divisions/remainders by 8192 and 64. This is the behavior in
Fog Machine's `FogMap.LngLatToGlobalXY` and `Tile.LngLatToXY`, with explicit
edge handling added for the exact dateline and Mercator limits.

## Bitmap orientation and checks

The canonical block is 512 bytes, row-major, top-to-bottom. For `(x, y)` in a
64 x 64 block, byte `y * 8 + floor(x / 8)` contains the bit
`7 - (x mod 8)`. Fog Machine's `Block.isVisited` and `Block.setPoint` confirm
MSB-first ordering. Its block extra data stores a 14-bit count/check value;
the observed invariant is `storedValue = 2 * popcount(bitmap) + 1`, with the
upper two bits reserved. The first two extra-data bytes also encode a two-letter
region value. `@@` is used for border/international coverage.

Fog tile headers are a 128 x 128 array of 16-bit block indices, stored
little-endian. Index zero means absent; nonzero indices address 515-byte block
records following the 32768-byte header. The index is sparse: block records are
packed after the header and the header position supplies the local block x/y.
Tile payloads are zlib-compressed.
The parser and Fog Machine agree on these dimensions, offsets, bit orientation,
and popcount validation.

## Native Fog containers

The sync representation is a `Sync/` directory or archive of obfuscated tile
filenames. The tile ID is `y * 512 + x`; the filename includes an MD5 prefix and
digit masks (`olhwjsktri` and `eizxdwknmo`). Fog Machine's FWSS writer uses a
ZIP archive with `Model/*` bitmap records, `Model/#` hash/metadata records, and
`Model/~` downsampled hierarchy records. FWSS base bitmap records retain the
same tile/block/bitmap geometry.

Fog Machine writes zlib payloads and uses little-endian block headers. FWSS also
contains a 4012-byte compressed metadata record, a compressed tile-index bitset,
hash records, and downsampled hierarchy layers. Some metadata semantics remain
reverse engineered rather than specified by Fog of World.

Fog Machine modifies a map by decoding each tile, changing canonical bitmap
bits, recomputing the observed block popcount check in `Block.dump`, rebuilding
the sparse tile header, and zlib-compressing the result. Empty blocks are
omitted from the sparse tile; an empty tile is omitted from a sync export. Its
editor can clear rectangles, but the parser README explicitly says that full
modification support and some metadata semantics remain TODO. The public code
does not establish a complete, version-negotiated native writer contract.

The observed native versions are the current sync tile payload (with no
explicit version field in the tile itself) and FWSS metadata version `2` in
`FwssArchive.ts`. These should not be generalized into a claim that all Fog
archives share one version. Unknown metadata/hash bytes are preserved only by
the reference implementation's record copying, not semantically understood.

## Issue reconciliation

The issue assumptions are directionally correct for the leaf geometry. #31's
requirement for 64x64 canonical blocks and #63's replaceable shards are
implemented; Fog's native zlib/ZIP/filename format is intentionally not reused
for Moves shards. `FogOfWorldKit` currently supports bitmap-bearing FWSS and
Sync ZIP entries, sparse tile decoding, checksum/popcount validation, and
deterministic Sync and FWSS export. FWSS hash/metadata/hierarchy records are
generated by the writer using the Fog Machine-compatible structural rules; the
reader exposes their counts and decodes the base `Model/*` bitmap records while
leaving private metadata semantics opaque.

## Moves storage boundary

Moves stores evidence as deterministic, CRC-protected `MVEXPLR1` source shards.
Each shard is bounded and replaceable and contains a source ID, revision,
optional logical date range, affected canonical block IDs, and separate bitmaps
for ground, visits, flights, and imported Fog evidence. The local merged cache
is disposable and stores the current per-layer union by canonical block.

These files are deliberately *not* native Fog sync/FWSS files. They do not use
Fog's obfuscated filenames, region bytes, ZIP hierarchy, zlib payloads, or FWSS
metadata. That native format belongs behind the future `FogOfWorldKit` boundary.
The shared contract is exact leaf-cell geometry and bitmap orientation, so a
future adapter can pack/unpack blocks without geographic resampling.

The initial shard format is uncompressed. This keeps deterministic validation,
atomic replacement, and corruption diagnosis simple while storage benchmarks
are gathered. Sparse block omission already avoids empty-world storage;
compression can be added as a versioned codec later without changing raster
identity.

The DEBUG importer persists an archive-hash checkpoint under
`v1/imports/<sha256>.json`. Completed tile IDs are written atomically after
their batch has been merged. Cancellation or termination therefore retries at
the last completed tile without committing a partial shard; existing stable
per-tile shards are also treated as idempotently complete.

## Known test vectors

- `(0°, 0°)` -> global cell `(2097152, 2097152)`, base tile `(256, 256)`,
  block `(32768, 32768)`, local bit `(0, 0)`.
- `(48.1374°, 11.5755°)` -> global cell `(2232016, 1455604)`, base tile
  `(272, 177)`, block `(34875, 22743)`, local bit `(16, 52)`.
- `(-33.8688°, 151.2093°)` -> base tile `(471, 307)`, block
  `(60294, 39327)`, local bit `(52, 41)`.
- `(-180°, 0°)` -> global cell `(0, 2097152)`.
- `(+180°, 0°)` wraps to the same cell as `(-180°, 0°)`.
- At the exact northern Mercator limit, `y = 0`; at the exact southern limit,
  `y = 2^22 - 1` after clamping.
- In a block, `(0, 0)` is byte 0 bit 7 and `(63, 63)` is byte 511 bit 0.

The executable reference tests live in `MovesTests/ExplorationTests.swift`.

## Known unknowns and limitations

- Fog Machine's native FWSS metadata, hash records, region semantics, and all
  format versions are not fully specified by the public reverse engineering.
- The package's Sync/FWSS export and bitmap-bearing FWSS/Sync import are
  validated with synthetic fixtures and Fog Machine-derived structure. A real
  user archive fixture is still required before claiming full Fog app
  acceptance, especially for metadata values and hierarchy semantics.
- The Fog Machine reference line rasterizer is suitable for geometry guidance,
  but the precise behavior of the Fog app for every antimeridian and sparse
  route case still needs fixture-based validation.
- No private Fog snapshot is committed. Future `FogOfWorldKit` fixtures must
  remain minimized and synthetic.
