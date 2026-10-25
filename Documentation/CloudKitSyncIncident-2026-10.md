# iPhone ↔ Mac CloudKit incident triage (October 2026)

Tracking issue: [#188](https://github.com/holgerkrupp/Moves/issues/188).

## Finding

The supplied incident establishes a real record-count divergence at two different observation times and an iPhone export event reported as `NSCocoaErrorDomain` 134419. It does **not** establish the exact failed transition. The incident snapshot has no record-ID comparison, effective signed environment, account-status observation, or Mac event history. Source inspection cannot determine whether the iPhone export reached CloudKit, whether the Mac imported the changes, or whether the Mac timeline omitted records already present in SwiftData.

The precise failure boundary remains a device-verification item. No store, schema, or CloudKit data reset is appropriate from the evidence available here.

## Confirmed source findings

- `Moves/SyncDiagnostics.swift` originally classified known CloudKit errors and `NSURLErrorDomain`, but did not recognize Cocoa error 134419. This caused a system deferral to display as an unknown error. It is now classified as retryable with explicit text that pending changes may not have uploaded.
- Diagnostics originally installed `NSPersistentCloudKitContainer.eventChangedNotification` observation only from `startObservingTimeline()`. The Mac called that from `MovesMacBrowser.onAppear` in `Mac/MovesMacApp.swift`, after creating the SwiftData container. Events between container opening and first browser appearance could therefore be missed. Both app entry points now install a bounded event buffer before opening the container; the diagnostics service drains it and continues observation before the UI appears. Timeline count queries remain deferred until the interactive timeline starts.
- The Status card's Retry action posted a request handled by `MovesAppRuntime.retryPreparation()`. For an already-ready store without an open failure, this method returned immediately and did not request CloudKit export. The card now calls this action “Refresh Diagnostics”; it refreshes the local snapshot only. A store setup failure retains a separate “Retry Store Setup” action.
- `Moves/TimelineStore.swift` centralizes the authoritative SwiftData schema and CloudKit container identifier. Both iOS and Mac app targets use `MovesTimelineStore.makeApplicationContainer()`. Their checked-in entitlements name `iCloud.de.holgerkrupp.Moves`. This establishes source-level parity, not the effective signing environment or account on either installed build.
- The iOS `Moves/Info.plist` includes the `remote-notification` background mode. The checked-in iOS and Mac entitlements both enable the same CloudKit container. The signed entitlements on the incident devices still need verification.
- The diagnostics snapshot uses bounded newest-record fetches and now includes the stable IDs of the newest local Place and Move. No coordinates, labels, route geometry, account identifiers, or CloudKit record payloads are added.
- A later successful event for the same stage supersedes its earlier error for active status. The earlier error remains in the local event history.

## Schema and workload assessment

Issue [#168](https://github.com/holgerkrupp/Moves/issues/168) documents a separate, previously verified Production schema rejection involving `VisitPlace.CD_regularPlaceID`. The supplied current incident contains no nested schema rejection text and does not establish Production as its effective environment. This work therefore makes no speculative schema change. If the device report contains a matching field rejection, follow #168's reviewed CloudKit Console procedure.

Issues [#78](https://github.com/holgerkrupp/Moves/issues/78) and [#79](https://github.com/holgerkrupp/Moves/issues/79) are closed as completed; source now includes shared per-device timing diagnostics and a single authoritative schema factory, though this incident demonstrates that their coverage needs follow-up. Issues [#140](https://github.com/holgerkrupp/Moves/issues/140) and [#145](https://github.com/holgerkrupp/Moves/issues/145) were closed as not planned and track database pressure and high-frequency synchronized samples. Repository source alone does not show that either caused this incident. The incident provides no SQLite timing, backlog, memory/thermal state, or export-duration measurements, so no background worker or authoritative model changes are justified by this report.

## Manual two-device boundary test

Use the procedure in [SyncLatencyBenchmark.md](SyncLatencyBenchmark.md). Verify the signed environment and account first, then create a new harmless Place/Move on each device in turn. Capture the source device's local-save timestamp and stable model ID, export start/completion, the read-only server record in that same environment, the receiving device's import event and local ID, and the visible timeline result. An absent ID at each successive checkpoint identifies the failed transition. Repeat Mac → iPhone, restart both apps, and allow one prolonged background interval. Compare IDs rather than totals, which can shift between capture times.

The present source can record successful event times and recent local IDs. It cannot read the installed signing entitlements, establish the signed CloudKit environment, inspect the user's CloudKit account, or verify a server record from within this repository-only investigation. Record those observations from the installed app/build-signing metadata and CloudKit Console without modifying server data.

## Device evidence required to close the root-cause question

- Both installed apps' effective `com.apple.developer.icloud-container-environment` signing entitlement and container identifier.
- Confirmation that both are signed into the same iCloud account and that each authoritative store opened in private CloudKit mode rather than the local fallback.
- Current per-device diagnostics after the observer change, including export/import timestamps, event causes, latest local IDs, and local counts.
- Read-only existence of the test record ID in the corresponding Development or Production private database.
- The reverse-direction test and post-restart/background catch-up result.

Until these observations exist, classify the incident as **cross-device divergence with an unproven transport/presentation boundary**, not as a verified iPhone export, Mac import, or timeline-cache failure.
