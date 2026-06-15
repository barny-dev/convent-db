# Revision history for convent-db

## 0.0.1.0 -- 2026-06-15

* Initial project scaffold (executable + basic test suite).
* Distilled and generalized storage design extracted from https://github.com/barny-dev/convent
  (FilePage.hs, EventsPage.hs, IndexPage.hs and lode/event-storage.md).
  - Removed all assumptions of "Events". Records are now opaque binary blobs
    ("binary record, not further specified").
  - Core abstractions captured: fixed-size page I/O (FilePage typeclass),
    variable-length record pages (pointer table + data packed from end),
    monotonic sparse index pages (1024 x uint64 keys).
  - Added human + agent friendly design documentation:
    - design/storage-format.md (layouts, algorithms, validation rules, rationale)
    - design/reference-types.hs (self-contained commented Haskell types/signatures ready for implementation)
* Updated package metadata and README to reference the design.

## Unreleased

* (future work: actual implementation of the storage primitives, store layer, etc.)
