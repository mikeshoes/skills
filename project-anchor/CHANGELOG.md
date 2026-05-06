# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-06

Initial release.

### Added
- `/project-anchor init` — bootstrap `north-star.md` from template with timestamp
- `/project-anchor audit` — drift detection across 4 signal types (change accumulation, north-star references, decisions log freshness, iteration-plan deviation), with 🟢/🟡/🔴 status and recommended actions
- `/project-anchor pivot` — formal pivot ceremony with 4-condition gate (evidence ≥ 2 sources / reversibility / user verbatim / iter boundary), writes `change` to `comms/open/`, appends to decisions log
- `assets/north-star-template.md` — interview-friendly template with anti-pattern examples
- `assets/audit-report-template.md` — drift audit output format
- `assets/pivot-change-template.md` — pivot change message format
- Standalone mode: works without `agent-orchestrator`'s `comms/` (lite audit, no change message)
