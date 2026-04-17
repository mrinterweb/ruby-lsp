# typed: strict
# frozen_string_literal: true

require "sqlite3"
require "digest/sha1"
require "fileutils"

module RubyIndexer
  class SQLiteStore
    # MethodAlias is intentionally absent: its target is a live reference to another Entry and
    # cannot be serialized. MethodAlias is always produced on-demand by Index#resolve_method_alias
    # from a stored UnresolvedMethodAlias, never persisted.
    ENTRY_TYPES = {
      "RubyIndexer::Entry::Module" => 0,
      "RubyIndexer::Entry::Class" => 1,
      "RubyIndexer::Entry::SingletonClass" => 2,
      "RubyIndexer::Entry::Method" => 3,
      "RubyIndexer::Entry::Accessor" => 4,
      "RubyIndexer::Entry::Constant" => 5,
      "RubyIndexer::Entry::GlobalVariable" => 6,
      "RubyIndexer::Entry::ClassVariable" => 7,
      "RubyIndexer::Entry::InstanceVariable" => 8,
      "RubyIndexer::Entry::UnresolvedConstantAlias" => 9,
      "RubyIndexer::Entry::ConstantAlias" => 10,
      "RubyIndexer::Entry::UnresolvedMethodAlias" => 11,
    }.freeze #: Hash[String, Integer]

    ENTRY_CLASSES = ENTRY_TYPES.invert.freeze #: Hash[Integer, String]

    VISIBILITY_MAP = { public: 0, protected: 1, private: 2 }.freeze #: Hash[Symbol, Integer]
    VISIBILITY_REVERSE = { 0 => :public, 1 => :protected, 2 => :private }.freeze #: Hash[Integer, Symbol]

    PARAM_TYPES = {
      "RubyIndexer::Entry::RequiredParameter" => 0,
      "RubyIndexer::Entry::OptionalParameter" => 1,
      "RubyIndexer::Entry::KeywordParameter" => 2,
      "RubyIndexer::Entry::OptionalKeywordParameter" => 3,
      "RubyIndexer::Entry::RestParameter" => 4,
      "RubyIndexer::Entry::KeywordRestParameter" => 5,
      "RubyIndexer::Entry::BlockParameter" => 6,
      "RubyIndexer::Entry::ForwardingParameter" => 7,
    }.freeze #: Hash[String, Integer]

    PARAM_CLASSES = PARAM_TYPES.invert.freeze #: Hash[Integer, String]

    MIXIN_TYPES = {
      "RubyIndexer::Entry::Include" => 0,
      "RubyIndexer::Entry::Prepend" => 1,
    }.freeze #: Hash[String, Integer]

    SCHEMA_VERSION = 4 #: Integer

    #: SQLite3::Database
    attr_reader :db

    class << self
      # Compute the on-disk cache path for a given workspace. The launcher (before the server
      # starts) and the server itself must agree on this path or the pre-indexed DB will never
      # be reused. Always pass the workspace directory as a String path (not a URI).
      #: (String workspace_path) -> String
      def db_path_for(workspace_path)
        db_dir = File.join(Dir.home, ".cache", "ruby-lsp", Digest::SHA1.hexdigest(workspace_path))
        FileUtils.mkdir_p(db_dir)
        File.join(db_dir, "index.db")
      end

      # Hash the current bundle's lockfile to detect gem changes. Both launcher and server run
      # this after Bundler.setup has activated the composed bundle, so they see the same
      # `Bundler.default_lockfile`.
      #: -> String
      def compute_lockfile_hash
        lockfile_path = begin
          Bundler.default_lockfile.to_s
        rescue Bundler::GemfileNotFound
          nil
        end

        content = if lockfile_path && File.exist?(lockfile_path)
          File.read(lockfile_path)
        else
          # Stdlib-only project — fall back to Ruby version so stdlib RBS is still cache-keyed.
          RUBY_VERSION
        end

        Digest::SHA1.hexdigest(content)
      end
    end

    #: (?String? db_path) -> void
    def initialize(db_path = nil)
      @db = SQLite3::Database.new(db_path || ":memory:")
      @db.results_as_hash = true
      @db.execute("PRAGMA journal_mode=WAL")
      @db.execute("PRAGMA synchronous=NORMAL")
      @db.execute("PRAGMA cache_size=-20000") # 20MB cache
      @uri_cache = {} #: Hash[String, URI::Generic]
      migrate_if_needed
      setup_schema
    end

    #: (Hash[String, Array[Entry]] entries, Array[[String, String]] require_paths) -> void
    def bulk_insert(entries, require_paths)
      @db.transaction do
        insert_entry = @db.prepare(<<~SQL)
          INSERT INTO entries (
            name, short_name, entry_type, uri, visibility,
            start_line, end_line, start_column, end_column,
            name_start_line, name_end_line, name_start_column, name_end_column,
            owner_name, parent_class, target, nesting, old_name, comments
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL

        insert_signature = @db.prepare(<<~SQL)
          INSERT INTO signatures (entry_id, position) VALUES (?, ?)
        SQL

        insert_parameter = @db.prepare(<<~SQL)
          INSERT INTO parameters (signature_id, name, param_type, position) VALUES (?, ?, ?, ?)
        SQL

        insert_mixin = @db.prepare(<<~SQL)
          INSERT INTO mixin_operations (entry_name, uri, operation_type, module_name, position) VALUES (?, ?, ?, ?, ?)
        SQL

        insert_require_path = @db.prepare(<<~SQL)
          INSERT OR REPLACE INTO require_paths (path, uri) VALUES (?, ?)
        SQL

        # Track the next insertion position per (entry_name, uri) so that multiple buffered
        # entries for the same namespace in the same file keep their mixin ops in source order.
        inserted_mixins = {} #: Hash[[String, String], Integer]

        entries.each_value do |entry_list|
          entry_list.each do |entry|
            entry_id = insert_single_entry(insert_entry, entry)

            case entry
            when Entry::Method
              entry.signatures.each_with_index do |sig, sig_pos|
                insert_signature.execute(entry_id, sig_pos)
                sig_id = @db.last_insert_row_id

                sig.parameters.each_with_index do |param, param_pos|
                  param_type = PARAM_TYPES[param.class.name] || 0
                  insert_parameter.execute(sig_id, param.name.to_s, param_type, param_pos)
                end
              end
            when Entry::Namespace
              entry_uri = entry.uri.to_s
              key = [entry.name, entry_uri]
              next_pos = inserted_mixins[key] || 0
              entry.mixin_operations.each_with_index do |op, i|
                op_type = MIXIN_TYPES[op.class.name] || 0
                insert_mixin.execute(entry.name, entry_uri, op_type, op.module_name, next_pos + i)
              end
              inserted_mixins[key] = next_pos + entry.mixin_operations.length
            end
          end
        end

        # Insert require paths explicitly recorded during indexing. We track them per-URI
        # (not per-entry) so empty files still register their require_path.
        require_paths.each do |path, uri_str|
          insert_require_path.execute(path, uri_str)
        end

        insert_entry.close
        insert_signature.close
        insert_parameter.close
        insert_mixin.close
        insert_require_path.close
      end
    end

    # Look up entries by fully qualified name
    #: (String name) -> Array[Entry]?
    def [](name)
      rows = @db.execute("SELECT * FROM entries WHERE name = ?", [name])
      return if rows.empty?

      materialize_entries(rows)
    end

    # Prefix search for autocompletion.
    # Results are ordered by name ASC so that shorter names (which are lexicographically less
    # than any extension with a longer suffix) appear before their extensions — matching the
    # in-memory PrefixTree's "leaf-before-descendants" collect behavior that callers rely on.
    #: (String query) -> Array[Array[Entry]]
    def prefix_search(query)
      return [] if query.empty?

      upper = prefix_upper_bound(query)
      singleton_type = ENTRY_TYPES["RubyIndexer::Entry::SingletonClass"]
      rows = @db.execute(
        "SELECT * FROM entries WHERE name >= ? AND name < ? AND entry_type != ? ORDER BY name ASC, id ASC",
        [query, upper, singleton_type],
      )
      return [] if rows.empty?

      # group_by is stable, so the resulting groups follow the first-row-per-name order above.
      rows.group_by { |r| r["name"] }.map { |_name, group| materialize_entries(group) }
    end

    # Get all entries for a URI
    #: (String uri) -> Array[Entry]?
    def entries_for(uri)
      rows = @db.execute("SELECT * FROM entries WHERE uri = ?", [uri])
      return if rows.empty?

      materialize_entries(rows)
    end

    # Search require paths by prefix
    #: (String query) -> Array[URI::Generic]
    def search_require_paths(query)
      upper = prefix_upper_bound(query)
      rows = @db.execute("SELECT * FROM require_paths WHERE path >= ? AND path < ?", [query, upper])
      rows.map do |r|
        uri = cached_uri(r["uri"])
        uri.require_path ||= r["path"]
        uri
      end
    end

    # Get all unique entry names
    #: -> Array[String]
    def names
      @db.execute("SELECT DISTINCT name FROM entries").map { |r| r["name"] }
    end

    # Check if a name exists
    #: (String name) -> bool
    def indexed?(name)
      result = @db.get_first_value("SELECT 1 FROM entries WHERE name = ? LIMIT 1", [name])
      !result.nil?
    end

    # Count of unique names
    #: -> Integer
    def length
      @db.get_first_value("SELECT COUNT(DISTINCT name) FROM entries") #: as Integer
    end

    #: -> bool
    def empty?
      length == 0
    end

    # Resolve an UnresolvedConstantAlias to a ConstantAlias in the database
    #: (String name, String target) -> void
    def resolve_constant_alias(name, target)
      @db.execute(
        "UPDATE entries SET entry_type = ?, target = ? WHERE name = ? AND entry_type = ?",
        [ENTRY_TYPES["RubyIndexer::Entry::ConstantAlias"], target, name, ENTRY_TYPES["RubyIndexer::Entry::UnresolvedConstantAlias"]],
      )
    end

    # Update the visibility of an entry in the database
    #: (String name, String uri, Integer start_line, Symbol visibility) -> void
    def update_visibility(name, uri, start_line, visibility)
      vis_int = VISIBILITY_MAP[visibility] || 0
      @db.execute(
        "UPDATE entries SET visibility = ? WHERE name = ? AND uri = ? AND start_line = ?",
        [vis_int, name, uri, start_line],
      )
    end

    # Delete all entries (and their owned rows) for a URI. Mixin operations are scoped by URI
    # so that re-indexing one file doesn't clobber mixin ops contributed by a different file
    # to the same namespace (e.g., a singleton reopened in multiple files).
    #: (String uri) -> void
    def delete(uri)
      @db.execute("DELETE FROM mixin_operations WHERE uri = ?", [uri])
      @db.execute("DELETE FROM require_paths WHERE uri = ?", [uri])
      # Entries cascade to signatures and parameters via foreign keys
      @db.execute("DELETE FROM entries WHERE uri = ?", [uri])
      @db.execute("DELETE FROM indexed_files WHERE uri = ?", [uri])
    end

    # Find the first entry whose full name equals `name` or whose last `::`-separated segment
    # equals `name`. Uses the indexed short_name column so the lookup stays O(log n) instead of
    # the full-table scan that `LIKE '%::name'` forces (leading wildcard disables the index).
    #: (String name) -> Array[Entry]?
    def first_unqualified_const(name)
      rows = @db.execute(
        "SELECT * FROM entries WHERE name = ? OR short_name = ? ORDER BY id LIMIT 50",
        [name, name],
      )
      return if rows.empty?

      materialize_entries(rows)
    end

    # Get all entry names matching a fuzzy query (returns just names for Jaro-Winkler filtering in Ruby)
    # Get all entries grouped by name. Callers that only need non-singleton entries can pass
    # exclude_singletons: true so the SingletonClass filter happens in SQL instead of after
    # materializing every row — a measurable win for large gem indexes where every class has a
    # companion singleton class.
    #: (?exclude_singletons: bool) -> Array[[String, Array[Entry]]]
    def all_entries_with_names(exclude_singletons: false)
      rows = if exclude_singletons
        singleton_type = ENTRY_TYPES["RubyIndexer::Entry::SingletonClass"]
        @db.execute("SELECT * FROM entries WHERE entry_type != ?", [singleton_type])
      else
        @db.execute("SELECT * FROM entries")
      end
      rows.group_by { |r| r["name"] }.map { |name, group| [name, materialize_entries(group)] }
    end

    # Check if a file has already been indexed with the same mtime
    #: (String uri, Integer mtime) -> bool
    def file_up_to_date?(uri, mtime)
      stored = @db.get_first_value("SELECT mtime FROM indexed_files WHERE uri = ?", [uri])
      stored == mtime
    end

    # Record the mtime for an indexed file
    #: (String uri, Integer mtime) -> void
    def set_file_mtime(uri, mtime)
      @db.execute("INSERT OR REPLACE INTO indexed_files (uri, mtime) VALUES (?, ?)", [uri, mtime])
    end

    # Store a metadata key-value pair
    #: (String key, String value) -> void
    def set_metadata(key, value)
      @db.execute("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)", [key, value])
    end

    # Retrieve a metadata value
    #: (String key) -> String?
    def get_metadata(key)
      @db.get_first_value("SELECT value FROM metadata WHERE key = ?", [key])
    end

    #: -> void
    def close
      @db.close
    end

    private

    # Drop all tables if schema version has changed, forcing a full rebuild
    #: -> void
    def migrate_if_needed
      current = begin
        @db.get_first_value("SELECT value FROM metadata WHERE key = 'schema_version'")
      rescue SQLite3::SQLException
        # metadata table doesn't exist yet — fresh DB
        nil
      end
      return if current.to_i == SCHEMA_VERSION

      @db.execute_batch(<<~SQL)
        DROP TABLE IF EXISTS parameters;
        DROP TABLE IF EXISTS signatures;
        DROP TABLE IF EXISTS mixin_operations;
        DROP TABLE IF EXISTS require_paths;
        DROP TABLE IF EXISTS indexed_files;
        DROP TABLE IF EXISTS entries;
        DROP TABLE IF EXISTS metadata;
      SQL
    end

    #: -> void
    def setup_schema
      @db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS entries (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          short_name TEXT NOT NULL,
          entry_type INTEGER NOT NULL,
          uri TEXT NOT NULL,
          visibility INTEGER NOT NULL DEFAULT 0,
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
          nesting TEXT,
          old_name TEXT,
          comments TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_entries_name ON entries(name);
        CREATE INDEX IF NOT EXISTS idx_entries_short_name ON entries(short_name);
        CREATE INDEX IF NOT EXISTS idx_entries_uri ON entries(uri);
        CREATE INDEX IF NOT EXISTS idx_entries_owner ON entries(owner_name);

        CREATE TABLE IF NOT EXISTS indexed_files (
          uri TEXT PRIMARY KEY,
          mtime INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS signatures (
          id INTEGER PRIMARY KEY,
          entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
          position INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_signatures_entry ON signatures(entry_id);

        CREATE TABLE IF NOT EXISTS parameters (
          id INTEGER PRIMARY KEY,
          signature_id INTEGER NOT NULL REFERENCES signatures(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          param_type INTEGER NOT NULL,
          position INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_parameters_sig ON parameters(signature_id);

        CREATE TABLE IF NOT EXISTS mixin_operations (
          id INTEGER PRIMARY KEY,
          entry_name TEXT NOT NULL,
          uri TEXT NOT NULL,
          operation_type INTEGER NOT NULL,
          module_name TEXT NOT NULL,
          position INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_mixin_entry ON mixin_operations(entry_name);
        CREATE INDEX IF NOT EXISTS idx_mixin_uri ON mixin_operations(uri);

        CREATE TABLE IF NOT EXISTS require_paths (
          path TEXT PRIMARY KEY,
          uri TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS metadata (
          key TEXT PRIMARY KEY,
          value TEXT
        );

        PRAGMA foreign_keys = ON;
      SQL

      set_metadata("schema_version", SCHEMA_VERSION.to_s)
    end

    #: (SQLite3::Statement stmt, Entry entry) -> Integer
    def insert_single_entry(stmt, entry)
      entry_type = ENTRY_TYPES[entry.class.name]
      raise ArgumentError, "Cannot persist #{entry.class.name} — no mapping in ENTRY_TYPES" unless entry_type

      visibility = VISIBILITY_MAP[entry.visibility] || 0
      loc = entry.location
      uri_str = entry.uri.to_s

      # Name location (for Namespace and Method entries)
      name_loc = if entry.respond_to?(:name_location) && entry.name_location != entry.location
        entry.name_location
      end

      # Owner name (for Member, ClassVariable, InstanceVariable, UnresolvedMethodAlias, MethodAlias)
      owner_name = entry.owner_name if entry.respond_to?(:owner_name)

      # Parent class (for Class entries)
      parent_class = entry.parent_class if entry.is_a?(Entry::Class)

      # Target (for aliases)
      target = case entry
      when Entry::UnresolvedConstantAlias, Entry::ConstantAlias
        entry.target
      end

      # Nesting (for Namespace and UnresolvedConstantAlias)
      nesting = case entry
      when Entry::Namespace
        entry.nesting.to_json
      when Entry::UnresolvedConstantAlias
        entry.nesting.to_json
      end

      # Old name (for UnresolvedMethodAlias)
      old_name = entry.old_name if entry.is_a?(Entry::UnresolvedMethodAlias)

      # Persist whatever was already collected. Gem entries are indexed with
      # collect_comments: false so @comments is nil for them — Entry#comments then lazily parses
      # the file on first access. RBS and workspace entries have a non-nil string to persist.
      comments = entry.instance_variable_get(:@comments)

      stmt.execute(
        entry.name,
        short_name_for(entry.name),
        entry_type,
        uri_str,
        visibility,
        loc.start_line,
        loc.end_line,
        loc.start_column,
        loc.end_column,
        name_loc&.start_line,
        name_loc&.end_line,
        name_loc&.start_column,
        name_loc&.end_column,
        owner_name,
        parent_class,
        target,
        nesting,
        old_name,
        comments,
      )

      @db.last_insert_row_id
    end

    # Extract the last `::`-separated segment of a fully qualified name so we can index it.
    # Used by first_unqualified_const to turn a "find `Foo`, wherever nested" lookup into an
    # indexed equality match rather than a full table scan via LIKE '%::Foo'.
    #: (String name) -> String
    def short_name_for(name)
      idx = name.rindex("::")
      idx ? name[(idx + 2)..] || name : name
    end

    #: (Array[Hash[String, untyped]] rows) -> Array[Entry]
    def materialize_entries(rows)
      signatures_by_entry = batch_load_signatures(rows)
      mixin_ops_by_name = batch_load_mixin_operations(rows)
      rows.map { |row| materialize_single_entry(row, signatures_by_entry, mixin_ops_by_name) }
    end

    # Load all signatures (and their parameters) for Method rows in at most two queries.
    #: (Array[Hash[String, untyped]] rows) -> Hash[Integer, Array[Entry::Signature]]
    def batch_load_signatures(rows)
      method_type = ENTRY_TYPES["RubyIndexer::Entry::Method"]
      method_ids = rows.filter_map { |row| row["id"] if row["entry_type"] == method_type }
      return {} if method_ids.empty?

      placeholders = method_ids.map { "?" }.join(",")
      sig_rows = @db.execute(
        "SELECT * FROM signatures WHERE entry_id IN (#{placeholders}) ORDER BY entry_id, position",
        method_ids,
      )
      sig_ids = sig_rows.map { |r| r["id"] }

      params_by_sig = {} #: Hash[Integer, Array[Hash[String, untyped]]]
      unless sig_ids.empty?
        param_placeholders = sig_ids.map { "?" }.join(",")
        param_rows = @db.execute(
          "SELECT * FROM parameters WHERE signature_id IN (#{param_placeholders}) ORDER BY signature_id, position",
          sig_ids,
        )
        param_rows.each { |pr| (params_by_sig[pr["signature_id"]] ||= []) << pr }
      end

      signatures_by_entry = {} #: Hash[Integer, Array[Entry::Signature]]
      sig_rows.each do |sr|
        sig_params = (params_by_sig[sr["id"]] || []).map { |pr| materialize_parameter(pr) }
        (signatures_by_entry[sr["entry_id"]] ||= []) << Entry::Signature.new(sig_params)
      end
      signatures_by_entry
    end

    # Load mixin operations for every namespace row in a single query, keyed by entry name so
    # reopens across URIs aggregate naturally. Previously this was an N+1 query per materialized
    # namespace, which dominated prefix_search that returned many classes/modules.
    #: (Array[Hash[String, untyped]] rows) -> Hash[String, Array[Entry::ModuleOperation]]
    def batch_load_mixin_operations(rows)
      namespace_types = [
        ENTRY_TYPES["RubyIndexer::Entry::Module"],
        ENTRY_TYPES["RubyIndexer::Entry::Class"],
        ENTRY_TYPES["RubyIndexer::Entry::SingletonClass"],
      ]
      namespace_names = rows.filter_map { |row| row["name"] if namespace_types.include?(row["entry_type"]) }.uniq
      return {} if namespace_names.empty?

      placeholders = namespace_names.map { "?" }.join(",")
      mixin_rows = @db.execute(
        "SELECT entry_name, operation_type, module_name FROM mixin_operations " \
          "WHERE entry_name IN (#{placeholders}) ORDER BY entry_name, uri, position",
        namespace_names,
      )

      ops_by_name = {} #: Hash[String, Array[Entry::ModuleOperation]]
      mixin_rows.each do |mr|
        op = mr["operation_type"] == 0 ? Entry::Include.new(mr["module_name"]) : Entry::Prepend.new(mr["module_name"])
        (ops_by_name[mr["entry_name"]] ||= []) << op
      end
      ops_by_name
    end

    #: (Hash[String, untyped] row, Hash[Integer, Array[Entry::Signature]] signatures_by_entry, Hash[String, Array[Entry::ModuleOperation]] mixin_ops_by_name) -> Entry
    def materialize_single_entry(row, signatures_by_entry, mixin_ops_by_name)
      uri = cached_uri(row["uri"])
      location = Location.new(row["start_line"], row["end_line"], row["start_column"], row["end_column"])

      name_location = if row["name_start_line"]
        Location.new(row["name_start_line"], row["name_end_line"], row["name_start_column"], row["name_end_column"])
      else
        location
      end

      visibility = VISIBILITY_REVERSE[row["visibility"]] || :public
      comments = row["comments"]
      entry_type = row["entry_type"]

      entry = case entry_type
      when 0 # Module
        nesting = row["nesting"] ? JSON.parse(row["nesting"]) : [row["name"]]
        e = Entry::Module.new(nesting, uri, location, name_location, comments)
        apply_mixin_operations(e, mixin_ops_by_name[row["name"]])
        e
      when 1 # Class
        nesting = row["nesting"] ? JSON.parse(row["nesting"]) : [row["name"]]
        e = Entry::Class.new(nesting, uri, location, name_location, comments, row["parent_class"])
        apply_mixin_operations(e, mixin_ops_by_name[row["name"]])
        e
      when 2 # SingletonClass
        nesting = row["nesting"] ? JSON.parse(row["nesting"]) : [row["name"]]
        e = Entry::SingletonClass.new(nesting, uri, location, name_location, comments, row["parent_class"])
        apply_mixin_operations(e, mixin_ops_by_name[row["name"]])
        e
      when 3 # Method
        signatures = signatures_by_entry[row["id"]] || []
        Entry::Method.new(row["name"], uri, location, name_location, comments, signatures, visibility, row["owner_name"])
      when 4 # Accessor
        Entry::Accessor.new(row["name"], uri, location, comments, visibility, row["owner_name"])
      when 5 # Constant
        Entry::Constant.new(row["name"], uri, location, comments)
      when 6 # GlobalVariable
        Entry::GlobalVariable.new(row["name"], uri, location, comments)
      when 7 # ClassVariable
        Entry::ClassVariable.new(row["name"], uri, location, comments, row["owner_name"])
      when 8 # InstanceVariable
        Entry::InstanceVariable.new(row["name"], uri, location, comments, row["owner_name"])
      when 9 # UnresolvedConstantAlias
        nesting = row["nesting"] ? JSON.parse(row["nesting"]) : []
        Entry::UnresolvedConstantAlias.new(row["target"], nesting, row["name"], uri, location, comments)
      when 10 # ConstantAlias
        unresolved = Entry::UnresolvedConstantAlias.new(row["target"], [], row["name"], uri, location, comments)
        Entry::ConstantAlias.new(row["target"], unresolved)
      when 11 # UnresolvedMethodAlias
        Entry::UnresolvedMethodAlias.new(row["name"], row["old_name"], row["owner_name"], uri, location, comments)
      else
        Entry::Constant.new(row["name"], uri, location, comments)
      end

      # Method and Accessor handle visibility in their constructors; set it for all other types
      entry.visibility = visibility unless entry_type == 3 || entry_type == 4
      entry
    end

    #: (Entry::Namespace entry, Array[Entry::ModuleOperation]? ops) -> void
    def apply_mixin_operations(entry, ops)
      return unless ops

      ops.each { |op| entry.mixin_operations << op }
    end

    #: (Hash[String, untyped] row) -> Entry::Parameter
    def materialize_parameter(row)
      name = row["name"].to_sym
      case row["param_type"]
      when 0 then Entry::RequiredParameter.new(name: name)
      when 1 then Entry::OptionalParameter.new(name: name)
      when 2 then Entry::KeywordParameter.new(name: name)
      when 3 then Entry::OptionalKeywordParameter.new(name: name)
      when 4 then Entry::RestParameter.new(name: name)
      when 5 then Entry::KeywordRestParameter.new(name: name)
      when 6 then Entry::BlockParameter.new(name: name)
      when 7 then Entry::ForwardingParameter.new
      else Entry::RequiredParameter.new(name: name)
      end
    end

    # Compute the upper bound for a prefix range query.
    # SQLite's default BINARY collation compares TEXT byte-by-byte, so we operate on bytes rather
    # than characters. This avoids producing invalid UTF-8 (e.g., surrogates) or relying on code
    # point arithmetic that doesn't line up with byte-wise comparison for multi-byte characters.
    #
    # The result is force-encoded back to UTF-8 (the bytes remain unchanged) so that the sqlite3
    # gem binds the parameter as TEXT. Binding as BLOB would collide with SQLite's type affinity
    # rules — every TEXT value compares less than any BLOB — which would cause the upper-bound
    # predicate `name < ?` to match every row.
    #: (String prefix) -> String
    def prefix_upper_bound(prefix)
      return prefix if prefix.empty?

      bytes = prefix.bytes
      i = bytes.length - 1
      i -= 1 while i >= 0 && bytes[i] == 0xFF

      # If every byte is 0xFF there is no strict upper bound in byte-lexicographic order; fall back
      # to a long sentinel. Ruby identifier names never start with 0xFF bytes in practice.
      return (prefix + ("\xFF".b * 32)).force_encoding(Encoding::UTF_8) if i < 0

      bytes[i] += 1
      bytes[0..i].pack("C*").force_encoding(Encoding::UTF_8)
    end

    #: (String uri_string) -> URI::Generic
    def cached_uri(uri_string)
      @uri_cache[uri_string] ||= URI(uri_string)
    end
  end
end
