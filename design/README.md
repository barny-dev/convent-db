# convent-db Design Documentation

This directory contains the authoritative description of the on-disk storage format
and core primitives for convent-db.

See:

- [storage-format.md](storage-format.md) — Full specification (human readable)
- [reference-types.hs](reference-types.hs) — Precise types and contracts (agent / implementer friendly)

The design is a direct generalization of the battle-tested page storage originally
developed in the "convent" chat platform prototype, with all event-specific concepts removed.
