# Ruby LSP Memory Reduction: Investigation & SQLite Index Plan

## Context

Ruby LSP consumes ~1.1 GB of reserved memory per instance on large projects. The hypothesis is that most of this memory is consumed by the in-memory `RubyIndexer::Index`, which stores every symbol (classes, modules, methods, constants, variables) for the workspace, all gems, and the Ruby stdlib.

This plan covers: (1) profiling to confirm where memory goes, (2) quick wins that could reduce memory without a major rewrite, and (3) a longer-term SQLite-backed index if needed.

---

## Phase 0: Profile Memory to Confirm the Hypothesis

Before changing anything, we need data. Run Ruby LSP against a large project and measure where memory actually goes.

**Steps:**
1. Write a script that initializes `GlobalState`, runs `index.index_all`, then uses `ObjectSpace.each_object` and `ObjectSpace.memsize_of_all` to measure:
   - Total Entry objects (count and size by type)
   - PrefixTree Node count and estimated size
   - `@entries` hash overhead
   - `@uris_to_entries` hash overhead
   - `@ancestors` cache size
   - **URI::Generic object count, size, and duplication ratio** (count unique URIs vs total Entry count to quantify sharing opportunity)
   - Location object count and size
   - **Duplicate string analysis**: count unique vs total `@name` strings, `nesting.join("::")` results, and URI `.to_s` values
2. Report a breakdown: what percentage of total memory is entries vs PrefixTree vs hashes vs URI objects vs other

**Key files:**
- `lib/ruby_indexer/lib/ruby_indexer/index.rb` (lines 52-83: the 5 data structures)
- `lib/ruby_lsp/global_state.rb` (line 60: creates the index)

---

## Phase 1: Quick Wins (Low Risk, Potentially High Impact)

### 1a. Deduplicate URI Objects Across Entries

Every `Entry` stores its own `URI::Generic` object (`entry.rb:27`), but all entries from the same file are semantically identical. A file with 50 methods/constants/ivars creates 50 separate `URI::Generic` objects, each carrying 8+ instance variables (`@scheme`, `@host`, `@port`, `@path`, etc.) plus the custom `@require_path`.

**Fix:** During indexing, intern URIs so that all entries from the same file share a single `URI::Generic` instance. Either:
- Maintain a `{ String => URI::Generic }` pool in the Index, keyed by path
- Or look up the existing URI from `@uris_to_entries` when adding entries and reuse it

**Impact on Index methods:**
- `index_single` / `add` -- look up or create URI, pass shared instance to all entries from that file
- No API changes needed -- entries still expose `uri` as before

**Estimated savings:** Potentially large. If 50K entries come from ~5K files, this eliminates ~45K `URI::Generic` objects (~3-5 MB of object overhead, plus reduced GC pressure).

**Files to modify:**
- `lib/ruby_indexer/lib/ruby_indexer/index.rb` (line 126: where entries are added with URIs, and `index_single`)
- `lib/ruby_indexer/lib/ruby_indexer/declaration_listener.rb` (URI creation during parsing)

### 1b. Deduplicate and Freeze Strings

Many strings are created dynamically during indexing and never deduplicated. Use `String#-@` (or `-"str"`) to intern frequently-used strings.

**Primary target -- `nesting.join("::")`:** This is the worst offender. Called 15+ times across `index.rb` alone (lines 188, 280, 285, 329, 430, 439, 448, 456, 516, etc.), often with the same nesting arrays, creating identical strings every time. Cache or intern these results.

**Secondary targets:**
- Entry `@name` strings (set in `entry.rb` line 26 and `namespace` line 130)
- Ancestor names in `@ancestors` cache
- Mixin operation module names

**Additional micro-optimization:** `index.rb:138` calls `delete_prefix("::")` on every `[]` lookup, allocating a new string even when the prefix isn't present. Guard with `start_with?` first:
```ruby
name = name.delete_prefix("::") if name.start_with?("::")
```

**Estimated savings:** 20-50 MB.

### 1c. Replace `@owner` Object References with Name Strings

`Entry::Member`, `Entry::InstanceVariable`, `Entry::ClassVariable`, `Entry::UnresolvedMethodAlias`, and `Entry::MethodAlias` all store `@owner` as a live reference to an `Entry::Namespace`. But the only thing ever accessed on it is `.name` (54 occurrences of `.owner&.name` or `.owner.name` across 9 files in production code).

**Replace with:** `@owner_name` (a String). This removes cross-entry object references, which also unblocks serialization for a potential SQLite backend.

**Note:** `MethodAlias.@target` is also a live object reference (`Entry::Member | Entry::MethodAlias`), but it delegates `.decorated_parameters`, `.formatted_signatures`, and `.signatures` -- not just `.name`. This reference must stay as-is (or be replaced with a lookup-on-access pattern in Phase 2).

**Test caveat:** `method_test.rb:615-620` uses `assert_same(bar.owner, baz.owner)` to verify singleton class identity sharing. Tests need updating to compare owner names instead of object identity.

**Files to modify:**
- `lib/ruby_indexer/lib/ruby_indexer/entry.rb` (Member, InstanceVariable, ClassVariable, UnresolvedMethodAlias, MethodAlias)
- `lib/ruby_indexer/lib/ruby_indexer/declaration_listener.rb` (passes `owner` to entry constructors -- change to pass `owner.name`)
- `lib/ruby_indexer/lib/ruby_indexer/rbs_indexer.rb`
- `lib/ruby_indexer/lib/ruby_indexer/index.rb` (13 locations with `.owner&.name` -- simplify to `.owner_name`)
- `lib/ruby_lsp/type_inferrer.rb`
- `lib/ruby_lsp/listeners/completion.rb`
- `lib/ruby_lsp/requests/completion_resolve.rb`
- 6 test files that reference `.owner`

### 1d. Remove `@configuration` Per Entry

Every Entry stores a `@configuration` reference (`entry.rb:25`). While this is a single shared object (not duplicated), the reference itself is 8 bytes per entry. For 50K+ entries, that's 400KB+ of identical pointers. Move configuration access to a class-level accessor or pass it at call sites where needed.

**Estimated savings:** Small (~0.5 MB), but reduces Entry object size which compounds with other optimizations.

**Files to modify:**
- `lib/ruby_indexer/lib/ruby_indexer/entry.rb` (remove from constructor, add class-level accessor)
- All callers that pass `configuration` to Entry constructors

### 1e. Replace PrefixTree with Radix Tree

The `PrefixTree` (`lib/ruby_indexer/lib/ruby_indexer/prefix_tree.rb`) creates one `Node` per character. Each Node has 5 instance variables: `@key`, `@value`, `@children` (Hash), `@parent`, `@leaf`.

**Important:** A sorted array + binary search is **not** a viable replacement. `PrefixTree.search()` collects all leaf values in a subtree via `node.collect` (`prefix_tree.rb:136-146`), which traverses descendants -- a fundamentally different operation from scanning a sorted array. Additionally, `prefix_search` in `index.rb:179-195` fires N+1 tree searches with nesting-aware query expansion. Binary search doesn't improve this pattern.

**Replace with:** A **radix tree (Patricia trie)** -- a compressed trie that merges single-child chains into single nodes. For `"Foo::Bar::Baz"`, instead of 13 nodes you get ~3 nodes. This preserves O(k) prefix search semantics and the `collect` subtree traversal, while reducing node count by an estimated 80-90%.

**Note:** `fuzzy_search` does NOT use PrefixTree at all -- it iterates `@entries` hash with Jaro-Winkler scoring (`index.rb:199-224`). This optimization has no impact on fuzzy search.

**Defer this until Phase 0 confirms PrefixTree is a significant memory consumer.** The "1.25M nodes" estimate in the original plan assumes no prefix sharing, but tries inherently share common prefixes. Actual node count may be much lower.

**Impact on Index methods:**
- `prefix_search` -- same API, just backed by radix tree
- `search_require_paths` -- same
- `delete` / `add` -- same

**Files to modify:**
- `lib/ruby_indexer/lib/ruby_indexer/prefix_tree.rb` (rewrite Node to store compressed key strings instead of single chars)
- `lib/ruby_indexer/lib/ruby_indexer/index.rb` (no changes needed if API stays the same)

### 1f. Compact Location into Data.define or Array

`Location` objects (`lib/ruby_indexer/lib/ruby_indexer/location.rb`) have 4 instance variables. Every entry has at least one; Namespace/Method entries have two (~100-150K total Location objects).

Using `Data.define(:start_line, :end_line, :start_column, :end_column)` is more memory-efficient than a plain class.

**Estimated savings:** ~1.5-3 MB. Lowest priority in Phase 1 -- do opportunistically.

---

## Phase 2: SQLite-Backed Index for Gem/Stdlib Entries (If Phase 1 Is Insufficient)

### Architecture: Hybrid In-Memory + SQLite

```
Index (facade - same public API)
  |
  +-- InMemoryStore  (workspace files - current data structures, small)
  |
  +-- SQLiteStore    (gems + stdlib - persistent on-disk database)
  |
  +-- @ancestors     (computed from both stores, stays in-memory, cached)
```

**Why hybrid:** Workspace files change on every keystroke and need lowest latency. Gems/stdlib are indexed once and rarely change. Gems/stdlib likely represent 80-90% of entries.

**Critical architectural constraint:** `linearized_ancestors_of` is a recursive graph traversal with cycle detection, nesting-aware name resolution, and order-dependent prepend/include semantics. It **cannot be expressed in SQL** and must remain in Ruby, operating over both stores. This limits SQLite's value for method resolution -- the ancestor chain must be computed in Ruby first, then used to query SQLite.

### SQLite Schema

```sql
CREATE TABLE entries (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  entry_type INTEGER NOT NULL,    -- enum: 0=Class, 1=Module, 2=Method, etc.
  uri TEXT NOT NULL,
  visibility INTEGER NOT NULL DEFAULT 0,  -- 0=public, 1=protected, 2=private
  start_line INTEGER NOT NULL,
  end_line INTEGER NOT NULL,
  start_column INTEGER NOT NULL,
  end_column INTEGER NOT NULL,
  name_start_line INTEGER,
  name_end_line INTEGER,
  name_start_column INTEGER,
  name_end_column INTEGER,
  owner_name TEXT,
  parent_class TEXT,
  target TEXT,
  comments TEXT,                  -- stored eagerly, not lazy-loaded
  nesting TEXT                    -- JSON array
);

CREATE INDEX idx_entries_name ON entries(name);
CREATE INDEX idx_entries_uri ON entries(uri);
CREATE INDEX idx_entries_owner ON entries(owner_name);

CREATE TABLE signatures (
  id INTEGER PRIMARY KEY,
  entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  position INTEGER NOT NULL
);

CREATE TABLE parameters (
  id INTEGER PRIMARY KEY,
  signature_id INTEGER NOT NULL REFERENCES signatures(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  param_type INTEGER NOT NULL,    -- enum for parameter types
  position INTEGER NOT NULL
);

CREATE TABLE mixin_operations (
  id INTEGER PRIMARY KEY,
  entry_name TEXT NOT NULL,       -- the namespace this mixin belongs to
  operation_type INTEGER NOT NULL, -- 0=include, 1=prepend
  module_name TEXT NOT NULL,
  position INTEGER NOT NULL       -- order within this entry_name (not global)
);

CREATE INDEX idx_mixin_entry ON mixin_operations(entry_name);

CREATE TABLE require_paths (
  path TEXT PRIMARY KEY,
  uri TEXT NOT NULL
);

CREATE TABLE metadata (
  key TEXT PRIMARY KEY,
  value TEXT
);
```

**Schema changes from original plan:**
- `entry_type` and `visibility` use integers instead of text (faster comparison, less space)
- Added `comments` column (entries need documentation for hover/completion)
- `mixin_operations.position` clarified as order within a single namespace entry, with index on `entry_name`
- `param_type` uses integer enum

### Query Method Mapping

| Index Method | SQLite Query | Notes |
|---|---|---|
| `#[](name)` | `SELECT * FROM entries WHERE name = ?` | |
| `#prefix_search(query)` | `SELECT * FROM entries WHERE name >= ? AND name < ?` | Range query using computed upper bound, not `LIKE` (index-friendly) |
| `#entries_for(uri)` | `SELECT * FROM entries WHERE uri = ?` | |
| `#delete(uri)` | `DELETE FROM entries WHERE uri = ?` | Cascades to signatures/parameters |
| `#resolve_method(name, recv)` | Compute ancestors in Ruby, then `SELECT * FROM entries WHERE name = ? AND owner_name IN (?)` | Ancestor chain must be computed in Ruby first |
| `#fuzzy_search(query)` | `SELECT DISTINCT name FROM entries` then compute Jaro-Winkler in Ruby | Cannot run fuzzy matching in SQL; loads only names, not full entries |
| `#search_require_paths(q)` | `SELECT * FROM require_paths WHERE path >= ? AND path < ?` | Range query, not `LIKE` |

### Alias Resolution Strategy

Lazy alias resolution (current behavior) mutates the index at query time:
- `UnresolvedConstantAlias` → `ConstantAlias` (`index.rb:920-930`)
- `UnresolvedMethodAlias` → `MethodAlias` (`index.rb:1057-1075`)

For SQLite, choose one approach:
1. **Eager resolution at index time** (preferred): Resolve all aliases during `index_single` before writing to SQLite. This means all gem/stdlib aliases are resolved once and stored as their final form. Trades slightly longer indexing for simpler query-time behavior.
2. **Lazy with write-back**: Allow query-time writes to SQLite when resolving aliases. Simpler to implement but adds write transactions during reads and complicates caching.

### Entry Materialization

SQLite rows get converted back to `Entry` objects via a factory:
```ruby
Entry.from_row(row, configuration) # dispatches to correct subclass
```

Objects are transient -- created per query, used, then GC'd. No long-lived Entry objects for gem data.

### Persistence Across Restarts

Store a hash of gem versions in the `metadata` table. On startup, compare against current `Bundler.locked_gems`. If unchanged, skip re-indexing gems entirely -- just open the existing SQLite file. This also speeds up startup time.

### Implementation Steps

1. **Extract Store interface** from Index -- define `add`, `delete_by_uri`, `lookup`, `prefix_search`, `entries_for_uri` methods
2. **Create InMemoryStore** wrapping current data structures, extracted from Index
3. **Refactor Index to delegate to InMemoryStore** -- verify all tests pass
4. **Create SQLiteStore** implementing the same interface
5. **Modify Index to use both stores** -- route gem/stdlib entries to SQLiteStore, workspace to InMemoryStore
6. **Add persistence** -- save/load SQLite DB, skip re-indexing unchanged gems
7. **Benchmark and tune** -- prepared statements, WAL mode, caching hot queries

### Key Risks

| Risk | Mitigation |
|---|---|
| SQLite latency on completions | Workspace stays in-memory; use prepared statements; benchmark |
| `sqlite3` gem dependency (not currently a dep) | Make optional; fall back to in-memory-only |
| Lazy alias resolution mutates entries | Eagerly resolve during indexing (preferred), or allow write-back |
| `MethodAlias.@target` is a live object ref | Replace with name-based lookup + re-resolve on access |
| `linearized_ancestors_of` can't run in SQL | Stays in Ruby; ancestor cache spans both stores |
| `fuzzy_search` requires all names in Ruby | Load only `DISTINCT name` column, not full entries |
| `nesting` JSON parse overhead on reads | Cache deserialized nesting arrays; most queries don't need nesting |

---

## Recommended Approach

1. **Phase 0** -- Profile to get actual numbers. Pay special attention to URI duplication ratio and PrefixTree node count.
2. **Phase 1a** -- URI deduplication. Simplest change, potentially large win, near-zero risk.
3. **Phase 1b** -- String dedup with `nesting.join("::")` caching as primary target.
4. **Phase 1c** -- `@owner` → `@owner_name` (also unblocks Phase 2 serialization).
5. **Phase 1d** -- Remove `@configuration` per entry (small, easy).
6. **Measure again** -- if memory is acceptable, stop here.
7. **Phase 1e** -- PrefixTree → radix tree. Only if Phase 0 confirms it's a significant contributor.
8. **Phase 1f** -- Location compaction (small win, do opportunistically).
9. **If still too high**, proceed to Phase 2 (SQLite for gems/stdlib). Must resolve alias resolution strategy and `MethodAlias.@target` live reference first.

Phase 1 changes are independently valuable and lay groundwork for Phase 2 if needed. The `@owner` → `@owner_name` change (1c) is required for SQLite serialization regardless.

---

## Verification

- Run full test suite: `bundle exec rake` (covers all index tests)
- Run specific index tests: `bin/test test/ruby_indexer/test/index_test.rb`
- Memory benchmarking script (to be written in Phase 0)
- Latency benchmarking for key operations: `resolve`, `prefix_search`, `method_completion_candidates`
