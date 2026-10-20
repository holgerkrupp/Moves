# Exploration performance gate

Exploration work is intentionally lower priority than recording, timeline
navigation, scrolling, search, imports, and launch.

Current bounds:

- one `DayTimeline` per preparation slice by default;
- one complete `DayTimeline` source unit per commit; route and visit inputs are
  no longer silently truncated by per-day counts;
- one durable queue claim at a time;
- 16 Fog tile shards per cache merge batch;
- dated country-presence entries are generated as derived data and updated or
  removed per source day;
- block rebuilds use a versioned block-to-source manifest; append-only updates
  union into the existing canonical block, while replacements read only source
  shards that contribute to affected blocks;
- render updates consume affected canonical blocks, and country presence is
  stored as per-day files so normal day processing does not rewrite all history;
- the manifest has a pending-mutation journal and a one-time full rebuild path
  for legacy stores or crash recovery;
- country attribution prefilters each multipolygon component by its own bounds
  before exact cell-clipping work;
- route geometry is released after the day work unit;
- leases and exponential per-item retry backoff make cancellation, process
  termination, and transient failures retryable without monopolizing a window;
- no Exploration fetch is launched from SwiftUI body evaluation.

Exploration shards, checkpoints, queues, caches, and indexes use
`NSFileProtectionCompleteUntilFirstUserAuthentication`. This keeps derived
Exploration available to background work after the first unlock following
reboot, including while the device is locked. These files contain derived
travel-presence and raster data, so this trades the stronger between-unlocks
protection of `NSFileProtectionComplete` for background availability. The
authoritative SwiftData/CloudKit timeline and user-selected Fog archives keep
their existing protection. Existing files are migrated in resumable batches
only inside `Application Support/Moves/Exploration`.

The worker is default-disabled until a device-history baseline is measured. The
DEBUG build contains `OSSignposter` instrumentation for shard generation and
the file-backed stages are separable in Instruments.

The current local verification evidence is:

- 25 Exploration XCTest cases pass when run from the built test bundle;
- the synthetic shard benchmark takes about 2.1 seconds for 100k/1m/10m
  cell-size samples on the development Mac and remains below 1.3 MB for the
  10-million-cell sample;
- macOS build-for-testing passes;
- iOS simulator build-for-testing passes.

Still required before enabling automatic preparation or normal Exploration UI:

1. Capture cold/warm launch, Timeline scroll/navigation, historical-day open,
   search, large-import throughput, CPU, memory, and main-thread hitch baselines
   on representative devices.
2. Repeat those measurements with a multi-year backlog, imported shards, and
   cache rebuilds active.
3. Benchmark iCloud Drive and private CloudKit/CKAsset transport separately.

If any repeat shows a material regression, reduce slice size/concurrency or
defer the work; do not enable the rollout.
