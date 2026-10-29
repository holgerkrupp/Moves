# Timeline and flight inference invariants

## Engineering Philosophy — Pragmatic Solo Developer

This project is maintained by a solo developer, often as a free, open-source application with a small user base. Optimize for useful, reliable software with minimal complexity and maintenance effort. Do not apply big-company processes or engineering standards unless explicitly requested.

This section is the default decision rule for scope, testing, and implementation effort. Preserve explicit project-specific requirements, especially data safety, privacy, security, platform constraints, and documented user-visible behavior. Interpret generic checklists proportionally to the change rather than expanding every task into a major project.

### 1. Simplicity first

- Prefer the simplest implementation that solves the actual problem for realistic users.
- Follow existing architecture, patterns, and native platform APIs.
- Avoid unnecessary abstractions, protocols, layers, dependencies, configuration, and infrastructure.
- Do not build generic frameworks for one-off functionality or speculate about future use.
- Prefer small, understandable changes over large rewrites; remove obsolete code when safe.
- If a simple approach handles roughly 90–95% of realistic cases, prefer it over a much more complex approach to theoretical completeness, unless the remainder risks user data, security, or essential functionality.

### 2. Requirements and scope

- Implement the requested outcome without inventing additional requirements.
- Distinguish essential behavior from optional enhancements.
- Cover common usage and observed failures; do not chase every hypothetical edge case.
- Do not create follow-up issues or expand GitHub acceptance criteria for speculative improvements.
- Do not block a task for nice-to-have refinements, exhaustive compatibility work, or theoretical future-proofing.
- When requirements are ambiguous but low-risk, choose a reasonable default and proceed.

### 3. Proportional testing

- Testing effort must match the change's complexity and risk.
- Add focused tests for important domain logic, migrations, data integrity, and confirmed regressions where practical.
- Do not require unit tests for every function, view, or trivial code change.
- Do not introduce elaborate mocks, test harnesses, or dependencies solely for coverage.
- A successful build plus targeted checks is enough for many small changes.
- Manual validation may cover device-specific UI, hardware, and platform behavior. Clearly state what remains to be checked, but do not keep implementation issues open solely for unavailable physical-device verification.
- Never claim a build or test passed when it was not run.

### 4. Reliability without overengineering

Prioritize, in order: (1) avoiding user-data loss or corruption, (2) avoiding common crashes and freezes, (3) keeping core functionality working, and (4) recoverable, understandable failures.

- Handle likely and observed errors; avoid defensive machinery for implausible scenarios.
- Prefer graceful degradation and straightforward recovery over elaborate retry systems.
- Use non-blocking feedback for recoverable background errors; do not interrupt users unnecessarily.
- Do not silently discard data or suppress failures requiring user action.
- Security, privacy, authentication, and irreversible operations deserve extra care even in a small app.

### 5. Architecture and performance

- Refactor only what is necessary for the requested change or an evidenced problem.
- Prefer incremental improvements, existing services, and established patterns.
- Do not maintain parallel implementations without a concrete migration reason.
- Optimize reported or measured user-visible slowness; avoid speculative caches, concurrency systems, and benchmarks.
- Accept small inefficiencies when the alternative adds substantial maintenance burden.

### 6. Definition of done

A task is done when the requested behavior is implemented, the relevant build/checks have been attempted where the environment allows, important regressions have been reasonably checked, and no serious new issue is known.

The following are **not automatic release gates**: exhaustive edge-case coverage, complete unit/UI test coverage, formal benchmarks, extensive architecture documentation, future-proof abstractions, old development-schema compatibility, extra settings, or physical-device verification unavailable to the agent.

Respect any explicit, narrower project requirement that applies to the task. Do not confuse optional improvements with blockers.

### 7. Agent behavior and communication

- Favor working software and clear maintenance over theoretical perfection.
- Do the work rather than turning small requests into lengthy plans.
- Ask for clarification only when the decision materially affects functionality, user data, security, or architecture.
- Keep changes focused and summaries concise: what changed, what was verified, and any real remaining risk.
- Recommend further work only when it has clear practical value.
- Never hide limitations, invent verification results, or compromise essential user-data protection.

**Guiding principle: Good enough, reliable, understandable, and shipped is usually better than theoretically perfect but excessively complex.**

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

## User documentation

- Update `Moves/MovesHelp.swift` and `Documentation/UserGuide.md` whenever a
  released feature, setting, permission, platform entry point, or workflow that
  appears in user help changes. Keep the topic inventory and platform coverage
  accurate.
- Keep iOS Documentation and macOS Moves Help aligned through the shared help
  topic library. Preserve Mac-specific help for the sidebar, inspector, import
  queue, Quick Look, and keyboard shortcuts.
- Describe only released behavior; do not advertise `#if DEBUG` Exploration or
  Photos interfaces as user features. Keep platform-specific recording guidance
  accurate and distinguish sync from export and backup.
- Preserve Move Mapping coverage from `TransportMode` and `MovesPalette`; do not
  introduce a second static mode/color table. Clearly distinguish recorded GPS,
  imported geometry, matched display routes, and inferred flight connectors.
- Keep help content offline and independent of timeline history. Do not query
  user records or initialize tracking, import, map, network, or CloudKit work to
  display help.
