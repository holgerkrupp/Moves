# Moves sync latency benchmark

This benchmark measures the existing managed SwiftData/CloudKit path end to end. It is intentionally repeatable after each sync optimization and does not claim that a CloudKit event means every record is already visible in the other app.

## Procedure

1. Keep iPhone and Mac online, signed into the same private iCloud container, with both apps active.
2. Start a fresh diagnostics export on both devices.
3. Create or receive a Visit on iPhone that produces a new Place and Move.
4. Record the iPhone `localSave` event, then its `cloudKitExport` start/end event.
5. Record the Mac `cloudKitImport` start/end event and first `localTimelineObservedChange` event containing the new counts/newest creation time.
6. Repeat at least 20 times and calculate median and p90 for each interval:
   - iPhone local save → export completion;
   - export completion → Mac import completion;
   - Mac import completion → first local observation;
   - iPhone local save → Mac first observation.
7. Repeat the same run with a large route import active. Compare record counts and event durations; a file import should not add one CloudKit-backed `LocationSample` row per route point.

The initial target is a median below 30 seconds and p90 below 2 minutes for normal incremental Place/Move visibility while both devices are active. Record device model, OS version, app build, network type, route-import state, sample count, median, p90, and any sync error summary alongside the results. Coordinates, labels, comments, and route geometry must not be included in diagnostics.

## Diagnostic event vocabulary

`cloudKitSetup`, `cloudKitImport`, and `cloudKitExport` mirror managed CloudKit transport events. `localSave` is emitted after a durable authoritative SwiftData save. `localTimelineObservedChange` is the compact post-import observation. The ring buffer retains the most recent 120 events on each device and is stored locally only.

## Fast-path spike decision

The recent-change fast path remains gated. The implementation does not write an auxiliary CloudKit overlay or duplicate the authoritative SwiftData record types. After the post-optimization benchmark is populated, close the gate with one measured decision:

- no ship if the managed path meets the target;
- hints only if they improve diagnosis/status without changing data display;
- a bounded, reconcilable overlay only if it demonstrates a material user-perceived improvement and passes offline, duplicate, deletion, and eventual-import tests.
