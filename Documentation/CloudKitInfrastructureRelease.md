# CloudKit infrastructure schema and release gate

`Configuration/CloudKitInfrastructureSchema.json` is the source of truth for
record types written directly through CloudKit. These records are infrastructure,
not SwiftData timeline entities.

## MovesWorkLease

`MovesWorkLease` lives in the private database of
`iCloud.de.holgerkrupp.Moves`, in `_defaultZone`. The app addresses each lease by
a deterministic record ID, so no custom query indexes are required. Conditional
saves provide acquisition and stale-takeover conflict protection.

The legacy `CrossDeviceWorkLease` SwiftData model remains in source only to open
and test old stores. It is intentionally absent from the authoritative timeline
schema. Existing local and CloudKit records are harmless and must not be deleted.

## Required release check

Before shipping a change that adds or changes direct CloudKit records:

1. Update the manifest in the same pull request and run
   `Scripts/check-cloudkit-schema.py`.
2. In the CloudKit Console for `iCloud.de.holgerkrupp.Moves`, verify the exact
   type, field types, optionality, and indexes in Development.
3. Deploy the schema changes from Development to Production. Development accepts
   undeployed types dynamically; Production does not.
4. Export or inspect the Production schema and compare it with the manifest.
5. Against Production, exercise create, fetch, conditional conflict, stale
   takeover, renew, and finish. Use a disposable lease record only—never reset a
   schema or recreate a user database.

The repository preflight proves that source and manifest agree. It cannot prove
that Apple’s Production environment has been deployed; the Console/`cktool`
verification is therefore a blocking manual release step.
