{-|
Module      : Convent.DB.Storage.Design
Description : Reference types and signatures for the Paged Binary Record Storage design.
Copyright   : (c) 2026 Barnaba Piotrowski
License     : MIT

This module is **not** meant to be built as part of the package yet.
It is a self-contained, heavily commented reference that captures the
distilled design (generalized from the "convent" prototype).

Use it as:
- A contract for the implementation (humans + agents).
- A place to evolve the design before moving types into src/.
- Documentation that is precise enough for direct code generation / porting.

All names are chosen to be general (Record instead of Event, Key instead of EventOffset, etc.).
-}

{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE AllowAmbiguousTypes #-}

module Convent.DB.Storage.Design
  ( -- * Page addressing
    PageIndex(..)
  , PageSize(..)
  , PagePtr
    -- * Low-level file page I/O
  , ReadError(..)
  , WriteError(..)
  , readRawPage
  , writeRawPage
    -- * FilePage typeclass (the core abstraction)
  , FilePage(..)
    -- * Record Page (variable-length binary records)
  , RecordPage
  , RecordPageError(..)
  , emptyRecordPage
  , addRecord
  , recordCount
  , recordAt
  , recordAtCopy
  , reserveBytes
    -- * Index Page (sparse monotonic key index)
  , IndexPage
  , IndexPageError(..)
  , AddIndexEntryError(..)
  , IndexEntry(..)
  , emptyIndexPage
  , addIndexEntry
  , indexEntryCount
  , indexEntries
  , indexEntryAt
    -- * Re-exports / utilities (for reference impl)
  , ByteString
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word16, Word64)
import Data.Kind (Type)
import System.Posix.Types (Fd)   -- or use Handle + a different backend
import qualified System.IO as IO  -- for alternative Handle-based impls

--------------------------------------------------------------------------------
-- Page Addressing
--------------------------------------------------------------------------------

-- | Zero-based page number within a file (or within a logical store).
newtype PageIndex = PageIndex Int
  deriving (Show, Eq, Ord, Num, Enum, Real, Integral)

-- | Size of one page in bytes. Usually 8192.
newtype PageSize = PageSize Int
  deriving (Show, Eq, Ord)

-- | A fully specified page location.
type PagePtr = (PageIndex, PageSize)

-- Recommended default for this design.
defaultPageSize :: PageSize
defaultPageSize = PageSize 8192

--------------------------------------------------------------------------------
-- Raw Page I/O (Low Level)
--------------------------------------------------------------------------------

-- | Errors from raw page reads (see FilePage.hs in the prototype).
data ReadError
  = ReadFileTooSmall !Int !Int          -- ^ required, actual
  | ReadInvalidPageIndex !PageIndex
  | ReadIOError !IO.IOError
  deriving (Show, Eq)

-- | Errors from raw page writes.
data WriteError
  = WriteInvalidPageIndex !PageIndex
  | WritePageSizeMismatch !PageSize !Int  -- ^ expected size, actual data length
  | WriteIOError !IO.IOError
  deriving (Show, Eq)

-- | Read exactly one page worth of bytes from the given location.
-- Implementations must validate index and file size.
readRawPage :: Fd -> PagePtr -> IO (Either ReadError ByteString)
-- (In a real implementation this would contain the Posix seek + readExact loop + fs checks.)

-- | Write exactly one page. Must fsync for durability (prototype does this).
writeRawPage :: Fd -> PagePtr -> ByteString -> IO (Either WriteError ())
-- (Implementation: seek, writeAll, fileSynchronise.)

--------------------------------------------------------------------------------
-- The FilePage Typeclass
--------------------------------------------------------------------------------

-- | Any data structure that can be stored in (and loaded from) a fixed-size
--   file page.  The typeclass gives uniform load/save while letting each
--   page kind define its own precise error types and (de)serialization.
class FilePage a where
  -- | Errors that can occur while parsing a page from bytes.
  data FilePageLoadError a :: Type

  -- | Errors that can occur while turning a page into bytes or writing it.
  data FilePageSaveError a :: Type

  -- | Serialize to the exact page-sized ByteString.
  toByteString   :: a -> Either (FilePageSaveError a) ByteString

  -- | Parse from a raw page-sized ByteString (must perform full validation).
  fromByteString :: ByteString -> Either (FilePageLoadError a) a

  -- | Map a low-level write error into this page type's save error.
  mapWriteError :: WriteError -> FilePageSaveError a

  -- | Map a low-level read error into this page type's load error.
  mapReadError  :: ReadError  -> FilePageLoadError a

  -- | Convenience: load + deserialize in one step.
  load :: Fd -> PagePtr -> IO (Either (FilePageLoadError a) a)
  load fd ptr = do
    raw <- readRawPage fd ptr
    pure $ case raw of
      Left e  -> Left (mapReadError e)
      Right b -> fromByteString b

  -- | Convenience: serialize + write in one step (with fsync on success path).
  save :: Fd -> PagePtr -> a -> IO (Either (FilePageSaveError a) ())
  save fd ptr page =
    case toByteString page of
      Left err -> pure (Left err)
      Right bs -> do
        res <- writeRawPage fd ptr bs
        pure $ case res of
          Left e  -> Left (mapWriteError e)
          Right () -> Right ()

--------------------------------------------------------------------------------
-- Record Page (variable-length opaque binary records)
--------------------------------------------------------------------------------

-- | A single 8192-byte page holding zero or more variable-length records.
--   The on-disk format uses a small pointer table at the front and packs
--   record data from the end of the page backwards (classic "heap from back").
newtype RecordPage = RecordPage ByteString
  deriving (Eq)

-- | All possible format errors when loading a RecordPage.
data RecordPageError
  = InvalidPageSizeError !Int
  | InvalidReservePtrError !Word16
  | InvalidRecordPtrError
      { offendingPtr      :: !Word16
      , offendingPtrIndex :: !Word16
      , offendingLimit    :: !Word16
      }
  deriving (Show, Eq)

-- | Create a fresh empty record page.
emptyRecordPage :: RecordPage
-- Implementation sketch:
--   reservePtr = 2, rest zeroed.

-- | Try to append a new opaque record.
--   Returns Nothing if there is not enough space (pointer + data).
addRecord :: RecordPage -> ByteString -> Maybe RecordPage
-- See prototype EventsPage.addEvent for the exact pointer arithmetic.

-- | Number of records currently stored in the page (derived from reservePtr).
recordCount :: RecordPage -> Word16

-- | Return the record at the given 0-based index inside this page (if exists).
--   The returned ByteString is a /view/ into the page (no copy unless you use recordAtCopy).
recordAt :: RecordPage -> Word16 -> Maybe ByteString

-- | Like 'recordAt' but guarantees an independent copy of the bytes.
recordAtCopy :: RecordPage -> Word16 -> Maybe ByteString

-- | Current free space in bytes (for data + the 2-byte pointer that would accompany it).
reserveBytes :: RecordPage -> Word16

-- | Load/Save instances (errors wrap the format error + raw IO errors).
instance FilePage RecordPage where
  data FilePageLoadError RecordPage
    = RecordFormatLoadError RecordPageError
    | RecordReadLoadError   ReadError
    deriving (Show, Eq)

  data FilePageSaveError RecordPage
    = RecordWriteSaveError WriteError
    deriving (Show, Eq)

  toByteString (RecordPage bs) = Right bs
  fromByteString bs = case {- validate and construct -} undefined of   -- real impl here
    Left e  -> Left (RecordFormatLoadError e)
    Right p -> Right p
  mapWriteError = RecordWriteSaveError
  mapReadError  = RecordReadLoadError

--------------------------------------------------------------------------------
-- Index Page (sparse monotonic keys)
--------------------------------------------------------------------------------

-- | 8192-byte page containing up to 1024 strictly-increasing 64-bit keys.
--   Zero entries mark the end of the populated prefix (and must be followed only by zeros).
newtype IndexPage = IndexPage ByteString
  deriving (Eq)

data IndexPageError
  = IndexInvalidPageSizeError !Int
  | IndexInvalidEntryError !Int
  | IndexNonZeroTrailingEntryError !Int
  | IndexNonAscendingKeyError !Int
  deriving (Show, Eq)

data AddIndexEntryError
  = IndexPageFull
  | NonAscendingKey
  deriving (Show, Eq)

-- | A single index entry: the minimum key present in the corresponding record page/segment.
newtype IndexEntry = IndexEntry
  { minimumKey :: Word64
  } deriving (Show, Eq)

emptyIndexPage :: IndexPage
-- all zeros

-- | Add a new minimum key. Must be strictly greater than the previous one.
addIndexEntry :: IndexPage -> Word64 -> Either AddIndexEntryError IndexPage

indexEntryCount :: IndexPage -> Int
-- number of non-zero leading entries (stops at first 0)

-- | All populated entries, in order.
indexEntries :: IndexPage -> [IndexEntry]

indexEntryAt :: IndexPage -> Int -> IndexEntry   -- may be the zero entry

instance FilePage IndexPage where
  data FilePageLoadError IndexPage
    = IndexFormatLoadError IndexPageError
    | IndexReadLoadError   ReadError
    deriving (Show, Eq)

  data FilePageSaveError IndexPage
    = IndexFormatSaveError IndexPageError
    | IndexWriteSaveError  WriteError
    deriving (Show, Eq)

  toByteString (IndexPage bs) = Right bs
  fromByteString bs = case {- full validation -} undefined of
    Left e  -> Left (IndexFormatLoadError e)
    Right p -> Right p
  mapWriteError = IndexWriteSaveError
  mapReadError  = IndexReadLoadError

--------------------------------------------------------------------------------
-- Notes for Implementers (very important for agents)
--------------------------------------------------------------------------------

{-|
1. Byte order is always big-endian for all on-disk integers.
2. Record data is completely opaque.  If you need typed records, prefix a
   1-byte type tag (and optionally a length) /inside/ the record ByteString
   yourself.
3. The index does NOT store the page number of the record page.  The mapping
   "index slot N <-> record page N" (or a segment start) is maintained by the
   store layer that sits on top of these primitives.
4. 'load' / 'save' via the FilePage instance must be the only way higher layers
   ever read or write typed pages.  This guarantees validation + error mapping.
5. When allocating a brand new page on disk, write the empty form first
   (emptyRecordPage or emptyIndexPage), then mutate via add* functions and save.
6. The prototype used both Fd+POSIX (with explicit fsync) and Handle-based
   versions. Choose one backend or abstract it.
7. All page kinds are 8192 bytes today.  If you ever make page size variable,
   you must version the on-disk format.
-}

-- | Handy pure big-endian readers/writers (no external deps).
--   (Copy of the style used in the original convent Util.ByteString.)
readW16BE :: ByteString -> Int -> Word16
readW64BE :: ByteString -> Int -> Word64
writeW64BE :: Word64 -> ByteString
