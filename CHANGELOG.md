# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-10-12

### Added
- Added non-fatal SDK warning callbacks and refreshed configuration on initialization.
- Added configurable retries for remote configuration fetches with a fallback publish endpoint.

### Changed
- Migrated local persistence to Hive CE and added retries for failed database writes.
- Improved event sync recovery, including preservation of halted batches.
- Renamed the package to `pulse_plus_events_sdk` (update package imports and dependencies).

## [1.1.0] - 2026-03-13

### Added
- Added onNetworkIntercept method to PulseEventsSdkConfig

### Changed
- Changed debug checks to release checks
- Updated error handling and validation
- Updated .gitignore file

## [1.0.0] - 2025-03-06

### Added
- Open-sourced the project under Apache License 2.0
- Comprehensive documentation in README.md
- Added CHANGELOG.md for version tracking

### Changed
- Updated package description to be more generic
- Removed internal references and dependencies
- Improved code comments and documentation

## [0.0.7] - Unreleased

### Added
- Initial version with core functionality
- Event tracking with priorities
- Background sync capabilities
- Configurable batching and retry mechanisms
- Offline support with local storage
