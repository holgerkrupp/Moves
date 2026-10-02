# Timeline and flight inference invariants

- A `Date` is an absolute instant. Use it for ordering, duration, overlap, and
  merge validation; never derive elapsed time from local calendar labels.
- A sparse significant-location sample is an observation, not an exact departure
  timestamp. Preserve `VisitPlace.departureDate` when it is authoritative and
  carry weak inferred timing confidence into automatic transport resolution.
- Automatic `.plane` is decided only by `AutomaticPlaneResolver`. Generic motion
  speed bucketing may produce a candidate but must not be treated as final flight
  evidence on its own.
- Direct distance above 1,000 km is sufficient automatic flight evidence. Below
  that threshold, use trustworthy elapsed time and/or a confirmed terrestrial
  route result. Offline, throttled, cancelled, timed-out, and transient MapKit
  failures are insufficient evidence, not “no route”.
- Probe short terrestrial candidates with walking/cycling-capable routing before
  final Plane classification. A valid terrestrial route prevents a flight label.
- A manual choice, imported declared mode, Health workout mode, or other explicit
  user metadata is authoritative and must not be rewritten by maintenance.
- Flight merge keeps one canonical `MoveSegment` owned by its absolute departure
  day. Samples retain their original `DayTimeline`; continuation-day rows are
  bounded presentation projections, never duplicate model relationships.
- Recorded route coordinates and inferred geodesic connectors are separate. Never
  persist connector points as `LocationSample` data or exported recorded GPS.
- Antimeridian polylines must be split at the ±180° boundary with matching edge
  points; never draw the long way around the globe.
