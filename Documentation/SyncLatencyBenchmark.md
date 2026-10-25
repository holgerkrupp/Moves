# Moves sync latency benchmark

This benchmark measures the existing managed SwiftData/CloudKit path end to end. It is intentionally repeatable after each sync optimization and does not claim that a CloudKit event means every record is already visible in the other app.

## Procedure

1. Keep both devices online and signed into the same iCloud account. Confirm each installed app's signed CloudKit container entitlement and effective environment (Development or Production); do not infer the environment from the Debug build setting.
2. Confirm each app opened the private CloudKit-backed store. A local-only fallback is not part of this cross-device test.
3. In CloudKit Console, use read-only inspection of the matching environment's private database. Do not modify the schema, zone, or records.
4. Copy diagnostics on both devices. Record each local record count, last successful import/export time, and newest local Place/Move IDs.
5. On iPhone, create one harmless identifiable Place/Move. Record its stable model IDs and local-save event time from the source diagnostics.
6. Record iPhone `cloudKitExport` start/completion. Check whether the same record ID exists in the server environment using the CloudKit Console record viewer.
7. Record Mac `cloudKitImport` start/completion and `localTimelineObservedChange`. Confirm the exact Place/Move ID appears in its diagnostic snapshot and timeline UI.
8. Repeat with a new harmless Mac edit and verify Mac export, server record, iPhone import, iPhone local ID, and iPhone UI.
9. Restart both apps and repeat once. Leave one app in the background for a prolonged interval, then verify deferred changes converge without removing either local store.
10. Repeat at least 20 times and calculate median and p90 for each interval:
   - iPhone local save → export completion;
   - export completion → Mac import completion;
   - Mac import completion → first local observation;
   - iPhone local save → Mac first observation.
11. Repeat the same run with a large route import active. Compare record counts and event durations; a file import should not add one CloudKit-backed `LocationSample` row per route point.

Use record IDs at each checkpoint to identify the boundary: absent after local save points to the local write; absent in the server points to export; present in the server but absent from Mac diagnostics points to import; present in diagnostics but absent from the UI points to presentation invalidation. Run the same checkpoints in reverse. Aggregate counts alone cannot identify the missing records.

The initial target is a median below 30 seconds and p90 below 2 minutes for normal incremental Place/Move visibility while both devices are active. Record device model, OS version, app build, signed environment, whether account status is available, network type, route-import state, sample count, median, p90, and any sync error summary alongside the results. Coordinates, labels, comments, account identifiers, and route geometry must not be included in diagnostics. Record stable model IDs only for the explicitly created test records.

## Diagnostic event vocabulary

`cloudKitSetup`, `cloudKitImport`, and `cloudKitExport` mirror managed CloudKit transport events. `localSave` is emitted after a durable authoritative SwiftData save. `localTimelineObservedChange` is the compact post-import observation. The ring buffer retains the most recent 120 events on each device and is stored locally only.

## Fast-path spike decision

The recent-change fast path remains gated. The implementation does not write an auxiliary CloudKit overlay or duplicate the authoritative SwiftData record types. After the post-optimization benchmark is populated, close the gate with one measured decision:

- no ship if the managed path meets the target;
- hints only if they improve diagnosis/status without changing data display;
- a bounded, reconcilable overlay only if it demonstrates a material user-perceived improvement and passes offline, duplicate, deletion, and eventual-import tests.
