# Exploration performance gate

Exploration work is intentionally lower priority than recording, timeline
navigation, scrolling, search, imports, and launch.

Current bounds:

- one `DayTimeline` per preparation slice by default;
- at most 64 routes, 100,000 affected blocks, and 20,000 visit cells per slice;
- one durable queue claim at a time;
- 16 Fog tile shards per cache merge batch;
- dated country-presence entries are generated as derived data and are
  invalidated with source replacements;
- route geometry is released after the day work unit;
- leases make cancellation and process termination retryable;
- no Exploration fetch is launched from SwiftUI body evaluation.

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
