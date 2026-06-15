# convent-db

A simple database.

## Design

The core on-disk format and primitives are documented in the `design/` directory:

- [design/storage-format.md](design/storage-format.md) — Complete human-readable specification (page layouts, algorithms, invariants, rationale).
- [design/reference-types.hs](design/reference-types.hs) — Precise, commented Haskell types + function signatures. Suitable for direct implementation or as a contract for agents/humans.

This design was **distilled** from the storage layer (`FilePage`, `EventsPage`, `IndexPage`) of https://github.com/barny-dev/convent and generalized:

- Removed all "event" / chat-specific assumptions.
- Records are now opaque binary blobs.
- The same fixed-page + pointer-table + monotonic sparse index approach remains.

The design favors simplicity, strong validation, append efficiency, and durability (fsync after page writes).

## Status

Early scaffold + design. Built with GHC 9.10 / Cabal 3.14.

## Building & Testing

```bash
cabal update
cabal build
cabal run convent-db
cabal test
```

## Author / Maintainer

Barnaba Piotrowski <barnaba.piotrowski@gmail.com>

License: MIT (see LICENSE)
