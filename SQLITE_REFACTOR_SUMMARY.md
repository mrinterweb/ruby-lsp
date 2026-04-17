# Ruby LSP SQLite Index Refactor — Summary

## Problem

Ruby LSP consumes ~1.1 GB of RSS on large Rails projects. The hypothesis was that the in-memory `RubyIndexer::Index` — storing every symbol (classes, modules, methods, constants, variables) for the workspace, all gems, and Ruby stdlib — is the primary consumer.

## Approach

Replace the in-memory index with an on-disk SQLite database. Gem/stdlib entries (which rarely change) live on disk. The SQLite DB persists across restarts, keyed by a hash of `Gemfile.lock`.

## Branch

`sqlite-refactor` — all work is on this branch.

## Results

| Scenario | RSS | Startup |
|----------|-----|---------|
| Original (main branch) | ~1,100 MB | ~1.3s |
| Phase 1 only (Entry slimming, no SQLite) | ~600 MB | ~1.3s |
| Gems in SQLite, workspace in memory | 186 MB | ~4s cached |
| **All entries in SQLite (current)** | **44 MB** | **~4s cached** |
| First run (building SQLite DB) | ~550 MB peak | ~13s |

## Commits on the branch

1. **`737b1b76`** — Entry slimming: URI dedup in RBS indexer, string interning, `@owner` → `@owner_name`, `@configuration` moved to class-level accessor
2. **`c277151b`** — SQLite-backed index for gem/stdlib entries (initial implementation, post-indexing offload)
3. **`2901de7b`** — SQLite persistence: skip gem re-indexing when `Gemfile.lock` unchanged
4. **`b733a6e7`** — Fix first-run performance: skip eager comment parsing during serialization (2m44s → 4.3s)
5. **`4c327530`** — (Reverted) Client-side restart notification approach
6. **`23a2abe1`** — Updated profiling script with timing, cache detection, DB file size
7. **`b3d6201a`** — Forked pre-indexing in launcher: child process builds SQLite DB, exits (freeing memory), server starts with clean heap
8. **`b7caaae7`** — WIP: All entries in SQLite (workspace + gems). 10 failures + 2 errors remaining.
9. **Latest uncommitted** — Fixes for visibility persistence, alias resolution caching, several test fixes. ~10 failures + 2 errors remaining.

## Architecture

### How it works

1. **Launcher** (`exe/ruby-lsp-launcher`): Before starting the server, checks if `~/.cache/ruby-lsp/<project-hash>/index.db` exists with a matching lockfile hash. If not, forks a child process that runs full indexing into SQLite, then exits (freeing all memory).

2. **Server starts** with a clean heap. Opens the cached SQLite DB. Indexes only workspace files (or all files if no cached DB).

3. **All entries** go to SQLite via a buffer. `add()` buffers entries; any read method triggers `flush_sqlite_buffer!` (read barrier pattern). Buffer size is 5000 entries.

4. **Fiber-based writer** during `index_all`: a fiber interleaves file parsing with SQLite flushes.

5. **Visibility changes** persist to SQLite via `set_entry_visibility()` / `update_visibility()`.

6. **Alias resolution** persists to SQLite via `resolve_constant_alias()`.

### Key files

- **`lib/ruby_indexer/lib/ruby_indexer/sqlite_store.rb`** (new) — SQLite schema, bulk insert, query methods, entry materialization
- **`lib/ruby_indexer/lib/ruby_indexer/index.rb`** — Removed `@entries`, `@entries_tree`, `@uris_to_entries`, `@require_paths_tree`. All queries go through SQLite. Read barrier flushes buffer before reads.
- **`lib/ruby_indexer/lib/ruby_indexer/entry.rb`** — `@owner` → `@owner_name` (String), `@configuration` → class-level accessor, string interning
- **`lib/ruby_indexer/lib/ruby_indexer/declaration_listener.rb`** — Passes `owner.name` instead of owner object, uses `set_entry_visibility()` for visibility mutations
- **`lib/ruby_indexer/lib/ruby_indexer/rbs_indexer.rb`** — URI caching, passes `owner.name`
- **`exe/ruby-lsp-launcher`** — Forked pre-indexing subprocess
- **`bin/profile_memory`** (new) — Memory profiling script
- **`ruby-lsp.gemspec`** — Added `sqlite3` dependency

### SQLite schema

- `entries` — all indexed symbols (name, type, URI, location, visibility, owner, parent_class, target, nesting, comments)
- `signatures` — method signatures (linked to entries)
- `parameters` — signature parameters (linked to signatures)
- `mixin_operations` — include/prepend operations (linked to namespace names)
- `require_paths` — require path → URI mapping
- `metadata` — key-value store (lockfile hash for cache invalidation)

### DB location

`~/.cache/ruby-lsp/<sha1-of-workspace-path>/index.db` (~25 MB for a large Rails app)

## What remains

### Failing tests (10 failures + 2 errors out of 318)

The all-SQLite WIP has these remaining failures:

1. **`test_searching_for_require_paths`** — Require paths returning nil from SQLite. The `search_require_paths` was partially fixed but may need the require path to be stored during `flush_sqlite_buffer!`.

2. **`test_singletons_are_excluded_from_prefix_search`** — `prefix_search` in SQLite was updated to exclude SingletonClass entries, but the test may expect different filtering behavior.

3. **`test_constant_completion_candidates_all_possible_constants`** — Completion returning too many or too few results.

4. **`test_instance_variable_completion_returns_class_variables_too`** — Wrong ordering of results.

5. **`test_handle_change_clears_ancestor_cache_if_tree_changed`** and **`test_handle_change_does_not_clear_ancestor_cache_if_tree_not_changed`** — `handle_change` was rewritten to use `entries_for` from SQLite for ancestor hash comparison. May need adjustment.

6. **`test_linearizing_circular_aliased_dependency`** and **`test_resolving_non_existing_self_referential_constant_alias`** — Circular alias detection affected by SQLite persistence of resolved aliases.

7. **`test_keeping_track_of_extended_modules`** — Extended module mixin operations may not be visible after flush.

8. **`test_enhancing_indexing_included_hook`** and **`test_advancing_namespace_stack_from_enhancement`** — Enhancement tests may need SQLite initialization or the enhancement API may need updating.

9. **`test_indexing_prism_fixtures_succeeds`** — Pre-existing failure (needs `git submodule update --init`).

### Common root causes

- **Materialization**: Some entry types don't fully reconstruct from SQLite (e.g., visibility not applied to all types — fixed, mixin operations on singletons)
- **Alias caching**: `resolve_alias` now persists to SQLite, but circular reference detection uses object identity which doesn't work with materialized objects — compare by name instead
- **Test infrastructure**: Tests that create their own `Index.new` need `initialize_sqlite_store!(db_path: ":memory:")` for isolation
- **Test expectations**: Some tests assert on specific entry counts or ordering that changed with the unified SQLite store

### Future improvements

- **Process restart optimization**: The launcher fork approach works but could be refined
- **Startup time**: First run is ~13s (vs 1.3s on main). Most time is SQLite serialization. Could be optimized with fewer transactions or parallel writing.
- **LRU cache**: Add a small in-memory cache for hot entries to reduce SQLite round-trips during completions
- **Shared gem cache**: Gems like `rails`, `activerecord` are the same across projects — a global cache DB would avoid per-project re-indexing

## How to test locally

### Run profiling script
```bash
cd ~/workspace/your-project
BUNDLE_GEMFILE=/Users/sean/code/ruby-lsp/Gemfile bundle exec ruby /Users/sean/code/ruby-lsp/bin/profile_memory
```

### Use in Neovim via Mason
```bash
# Back up Mason's ruby-lsp
mv ~/.local/share/nvim/mason/bin/ruby-lsp ~/.local/share/nvim/mason/bin/ruby-lsp.bak

# Create shim pointing to local branch
cat > ~/.local/share/nvim/mason/bin/ruby-lsp << 'SHIM'
#!/usr/bin/env ruby
load "/Users/sean/code/ruby-lsp/exe/ruby-lsp"
SHIM
chmod +x ~/.local/share/nvim/mason/bin/ruby-lsp
```

Also add to your project's Gemfile (don't commit):
```ruby
gem "ruby-lsp", path: "/Users/sean/code/ruby-lsp"
```

Then: `rm -f .ruby-lsp/Gemfile.lock .ruby-lsp/bundle_is_composed && bundle install`

### Restore original
```bash
mv ~/.local/share/nvim/mason/bin/ruby-lsp.bak ~/.local/share/nvim/mason/bin/ruby-lsp
```

### Clear cached DB
```bash
rm -rf ~/.cache/ruby-lsp/
```

### Run tests
```bash
bundle exec rake          # full suite
bundle exec rake test:indexer  # indexer tests only
bin/test lib/ruby_indexer/test/index_test.rb test_name  # single test
```

## Plan document

The original optimization plan is in `merry-wiggling-bird.md` at the project root.
