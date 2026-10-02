# Flight matching

Flight matching is an optional, user-triggered enrichment path for Moves with
`TransportMode.plane`. `FlightFingerprint` is a compact `Sendable` value and
contains only bounded route samples, timestamps, endpoints, distance, and
optional country hints. Timeline preparation and scrolling never instantiate
the matching service.

`FlightAirportResolver` uses the replaceable `AirportDatabase` abstraction and
returns zero or more candidates; it never fabricates airport codes. The
starter database is intentionally small and versioned in code until a fuller
airport dataset with compatible licensing is selected.

`HistoricalFlightProvider` is also an abstraction. The app currently ships
the matching pipeline and a fixture/in-memory provider for tests, but does not
ship credentials or silently select a commercial historical-flight service.
That keeps provider licensing, retention, rate limits, historical coverage,
and any server-side credential requirements explicit before production
networking is enabled.

The actor-backed `FlightMatchingService` bounds queries to a 12-hour window
on either side of the recorded flight and caches results for the lifetime of
the service. Confirmed, imported, and user-entered metadata is stored with
provenance on the Move. User-entered/imported values cannot be overwritten by
later provider suggestions. Provider suggestions remain replaceable and can be
marked stale when the Move is edited.

No bulk lookup is performed as part of Exploration preparation. A provider
integration should be added at the explicit `FlightMatchingView` boundary,
with a clear disclosure of the data sent and local caching/deletion behavior.
