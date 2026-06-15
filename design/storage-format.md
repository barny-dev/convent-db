# Paged Binary Record Storage Design

**Source**: Distilled and generalized from the core storage implementation in https://github.com/barny-dev/convent (specifically `FilePage.hs`, `EventsPage.hs`, `IndexPage.hs`, `PageOps.hs`, supporting utilities, and the `lode/event-storage.md` specification).

**Key Change**: The original design was specialized for "chat events". Here we remove all "event" assumptions. We store **opaque binary records** (variable-length `ByteString` blobs). The caller is responsible for any internal structure, length prefixes, or type tags *inside* a record if required. The storage layer treats records as black boxes.

This design is the foundation for **convent-db** — a simple, efficient, append-oriented database.

## Goals & Non-Goals

**Goals**
- Efficient append of binary records.
- Fixed-size pages → predictable I/O, easy memory-mapping potential, simple allocation.
- Fast within-page access by record index (0-based within page).
- Sparse index over a monotonic 64-bit key space for fast "find page containing key >= X" + subsequent scans.
- Strong format validation on every load (defensive).
- Durability control (explicit synchronisation).
- Minimal runtime dependencies (ByteString + low-level IO).
- Simple to implement and reason about.

**Non-Goals (for the core layer)**
- No built-in record schema / typing / compression (higher layers or record contents can provide).
- Not a full B-tree or LSM; intentionally simpler page + linear index.
- No multi-file transactions beyond per-page writes + fsync.
- No compaction / vacuum in the base layer (can be added on top).

## Page Size

- **Default / current**: 8192 bytes (`0x2000`).
- Rationale:
  - Matches common filesystem block sizes and OS page sizes.
  - 16-bit offsets are sufficient and cheap (pointer table overhead is low).
  - Good density for typical small-to-medium records (hundreds per page possible).
  - Easy mental math and alignment.
- The low-level `FilePage` abstraction is parameterized by `Size`, but the concrete `RecordPage` and `IndexPage` currently hard-code 8192. Changing page size would require coordinated format updates.

All offsets and pointers below assume page size = 8192 unless otherwise noted.

## 1. Low-Level Page I/O — `FilePage`

### Concepts
- `PageIndex` (newtype `Int`, 0-based).
- `PageSize` (newtype `Int`).
- `Ptr = (PageIndex, PageSize)`.
- Pages are always read/written as exact `pageSize` byte blocks at file offset `index * pageSize`.

### Raw Operations (Fd or Handle based)
- `read` (or equivalent): 
  - Validate index >= 0.
  - Check that file is large enough for the page.
  - Seek + read exactly `pageSize` bytes.
  - Errors: `ReadFileTooSmall`, `ReadInvalidPageIndex`, `ReadIOError`.
- `write`:
  - Same validations + exact size match of the data being written.
  - After write: `fsync` / `fileSynchronise` (durability over throughput).
  - Errors: `WriteInvalidPageIndex`, `WritePageSizeMismatch`, `WriteIOError`.

### The `FilePage` Typeclass (lifting raw pages to typed pages)
```haskell
class FilePage a where
  data FilePageLoadError a :: Type
  data FilePageSaveError a :: Type

  toByteString :: a -> Either (FilePageSaveError a) ByteString
  fromByteString :: ByteString -> Either (FilePageLoadError a) a

  mapWriteError :: WriteError -> FilePageSaveError a
  mapReadError  :: ReadError  -> FilePageLoadError a

  -- Provided default methods
  load :: Fd -> Ptr -> IO (Either (FilePageLoadError a) a)
  save :: Fd -> Ptr -> a -> IO (Either (FilePageSaveError a) ())
```

`RecordPage` and `IndexPage` (below) are instances. This gives uniform load/save while each page type owns its serialization and error taxonomy.

Utility: exact read/write loops that retry partial operations on Fd.

## 2. Record Page (generalized `EventsPage`)

A `RecordPage` holds 0 or more variable-length opaque binary records.

### On-Disk Layout (8192 bytes)

```
Offset  Size   Content
0       2      reservePtr : Word16 BE          (next pointer slot offset; min 2, even)
2       ...    Pointer table (Word16 BE each)  -- grows forward
...            (zero/reserve space)
P_i     ...    Record i data (last record ends at 8192)
...
8192
```

- **reservePtr** (at 0): current end of the pointer table. Starts at 2 for empty page.
  - Always even.
  - 2 <= reservePtr <= 8192.
- **Pointer table** (starting at byte 2): array of `Word16 BE` values.
  - Each value is the **byte offset of the start of the corresponding record**.
  - Pointers are written in order of insertion.
  - The first record added has its data at the very end of the page; its pointer is the highest.
- **Data area**: records are packed **backwards** from offset 8192 toward the pointer table.
  - No length prefix or padding inside the page for records.
  - Length of record `i` = pointer[i-1] - pointer[i]   (with pointer[-1] treated as 8192 for the first/oldest record in the page).
- **Reserve / free space**: `lastDataPtr - reservePtr`. Must be >= (2 + recordLength) to append.

All multi-byte integers are **big-endian**.

### Empty Page
`reservePtr = 2`, followed by 8190 zero bytes.

### Adding a Record (`addRecord`)
1. Compute current `count`, `rptr`, `lastPtr` (end of last record or 8192).
2. Required space = 2 (for new pointer) + len(record).
3. If `reserve < required` → cannot add (page full for this record).
4. `newRptr = rptr + 2`
5. `newPtr = lastPtr - len(record)`
6. Rebuild (or mutate) the page bytes:
   - New reservePtr
   - Copy previous pointer table + new pointer
   - Appropriate zero fill in the advanced pointer region
   - Place the record bytes at `newPtr`
   - Preserve any data after (the older records)
7. Return new `RecordPage`.

### Access
- `recordCount`
- `record page ix` → `Maybe ByteString` (zero-copy view or copy)
- Pointer for a record index.

### Validation (`fromByteString`)
Strict checks (any failure → load error):
- Exact page size 8192.
- `reservePtr` even, in [2, 8192].
- All pointers:
  - Strictly descending (each < previous).
  - >= reservePtr
  - < 8192
- No pointers into the reserved area.
- Trailing data after last pointer must be consistent with the last record reaching (or not) the page end.

`toByteString` is identity (the validated raw bytes).

Implements `FilePage`.

### Invariants
- Records are stored contiguously with no internal gaps.
- Pointer table exactly describes the record boundaries.
- Once written to disk (with fsync), a page is immutable or append-only within the same page until a new page is allocated.

## 3. Index Page (generalized `IndexPage`)

Provides a sparse, sorted index over record keys (monotonic 64-bit values assigned by the store, e.g. a global sequence number or timestamp-based key).

### On-Disk Layout (8192 bytes)

```
Offset   Content
0        Word64 BE  minKey[0]   (0 = unused)
8        Word64 BE  minKey[1]
...
(1024 * 8 = 8192 bytes total)
```

- Max 1024 entries (`8192 / 8`).
- Entries are **strictly increasing** when non-zero.
- The list is **zero-terminated**: the first zero entry marks the end of valid entries. All following bytes must also be zero (enforced on load and add).
- Each non-zero entry stores the **minimum key** of the records present in the corresponding data (record) page/segment.

### Operations
- `emptyPage` = all zeros.
- `addEntry page newMinKey`:
  - Must be > previous entry's key (strictly ascending).
  - Must not exceed 1024 entries.
  - On success: writes the key at the next slot, zeros the rest.
- `entryCount`, `entries` (list of non-zero), `entry ix`.
- Validation on `fromByteString`:
  - Size == 8192.
  - Strictly ascending until first zero.
  - No non-zero values after a zero.
  - (The mapping from index slot → record page is managed by the store layer.)

Implements `FilePage`.

### Purpose in the Store
The index lets the database quickly locate the record page that *may* contain records for a given key without scanning every data page. Typically:
- There is (logically) one index entry per record page.
- Entry N corresponds to record page N (or a segment start).
- To find records with key >= K: binary search or linear scan the index pages to find the rightmost entry whose minKey <= K, then open that record page (and possibly subsequent pages) and scan/filter.

Multiple index pages can be chained if >1024 record pages exist.

## 4. Higher-Level Composition (Store Layer Sketch)

A full "simple database" built on this would typically have:

- One (or more) **record data file(s)** containing a sequence of `RecordPage`s (page 0, 1, 2, ...).
- One (or more) **index file(s)** containing `IndexPage`s.
- A small header or sidecar for:
  - Current append page index.
  - Next monotonic key to assign.
  - Number of committed pages / entries.
- On append(record, optionalKey):
  1. Assign next key if not provided.
  2. Load last record page (or allocate new).
  3. Try `addRecord`. On full → allocate new page, write it, update "current page".
  4. If the new page is the first record for a new index slot, or min key for the page, call `addEntry` on the appropriate index page.
  5. Persist with proper ordering + fsyncs.
- Lookups by key use the index pages to jump to candidate record page(s), then linear scan + filter within page(s) (and across page boundaries for range queries).

Separate files for records vs indexes is common (or a single file with typed pages + a directory of pages).

The `FilePage` + typed pages give a clean way to implement typed load/save for both.

## 5. Error Handling & Validation Philosophy

- Every loaded page is fully validated before use.
- Separate error types per layer (low-level IO vs format vs semantic).
- The typeclass `FilePage` forces every page type to declare its precise load/save errors.
- Defensive: better to refuse a corrupt page than to return garbage data.

## 6. Durability & Concurrency Notes

- Writes are followed by `fsync` in the base `FilePage.write`.
- No built-in locking or MVCC in this layer (higher layer or OS file locking can be added).
- Pages are append-friendly within a page; cross-page allocation is the responsibility of the store.
- The design favors simplicity and auditability over maximum write throughput.

## 7. Binary Encoding Details

- All integers: big-endian (network order).
- No compression.
- Records: completely opaque. Recommended convention for users of the DB (not enforced):
  - First byte: record type tag (if polymorphic records).
  - Next bytes: length or other header if variable inside the blob.
- Pointers/offsets are relative to the start of the *page*.

## Example Record Page (after a few appends)

(See the original `lode/event-storage.md` for a worked numeric example with three items; replace "Event N" with "Record N". The math is identical.)

## References (original implementation)

- `lib/Web/Convent/Storage/FilePage.hs`
- `lib/Web/Convent/Storage/EventsPage.hs`
- `lib/Web/Convent/Storage/IndexPage.hs`
- `lib/Web/Convent/Storage/PageOps.hs`
- `lode/event-storage.md` (and related lode/ docs)
- `lib/Web/Convent/Util/ByteString.hs` (manual BE readers/writers)

This document + `reference-types.hs` together form the complete, implementation-ready specification for the core on-disk format and primitives of convent-db.
