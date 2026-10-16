# Changelog

## 0.2.0

- RunLoop probe retains 64 qualifying completed intervals and reports observed end boundaries.
- Hang events preserve initial breadcrumbs/context; recovery enriches spans/resources.
- Bounded per-ID delivery coalesces updates, reserves terminal capacity and exposes loss counters.
- Added business spans/signposts, process CPU/memory sampling, frame-cadence windows and weak lifetime observations.
- Added previous-session evidence with unknown exit attribution and version-tolerant MetricKit raw archives.
- Added byte/age-bounded batch persistence, legacy archive decoding and versioned diagnostic export.
- Expanded the example into an interactive experiment lab with before/after scheduling controls.
- Added regression comparison tooling, boundary tests and simulator launch/persistence smoke checks.
- Migration: HangPhase adds cancelled; callbacks may skip detected and deliver a complete recovered event.
  MetricKit receive callbacks now run on a private background queue.

## 0.1.0

- Initial RunLoop hang monitor, breadcrumbs, bounded event archive, MetricKit adapter and example.
