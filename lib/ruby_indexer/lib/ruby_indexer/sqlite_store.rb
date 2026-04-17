# typed: strict
# frozen_string_literal: true

require "sqlite3"

module RubyIndexer
  class SQLiteStore
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
      "RubyIndexer::Entry::MethodAlias" => 12,
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

    #: SQLite3::Database
    attr_reader :db

    #: (?String? db_path) -> void
    def initialize(db_path = nil)
      @db = SQLite3::Database.new(db_path || ":memory:")
      @db.results_as_hash = true
      @db.execute("PRAGMA journal_mode=WAL")
      @db.execute("PRAGMA synchronous=NORMAL")
      @db.execute("PRAGMA cache_size=-20000") # 20MB cache
      @uri_cache = {} #: Hash[String, URI::Generic]
      setup_schema
    end

    #: (Hash[String, Array[Entry]] entries, Hash[String, Array[Entry]] uris_to_entries, untyped? _require_paths_tree) -> void
    def bulk_insert(entries, uris_to_entries, _require_paths_tree = nil)
      @db.transaction do
        insert_entry = @db.prepare(<<~SQL)
          INSERT INTO entries (
            name, entry_type, uri, visibility,
            start_line, end_line, start_column, end_column,
            name_start_line, name_end_line, name_start_column, name_end_column,
            owner_name, parent_class, target, nesting, old_name, comments
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL

        insert_signature = @db.prepare(<<~SQL)
          INSERT INTO signatures (entry_id, position) VALUES (?, ?)
        SQL

        insert_parameter = @db.prepare(<<~SQL)
          INSERT INTO parameters (signature_id, name, param_type, position) VALUES (?, ?, ?, ?)
        SQL

        insert_mixin = @db.prepare(<<~SQL)
          INSERT INTO mixin_operations (entry_name, operation_type, module_name, position) VALUES (?, ?, ?, ?)
        SQL

        insert_require_path = @db.prepare(<<~SQL)
          INSERT OR IGNORE INTO require_paths (path, uri) VALUES (?, ?)
        SQL

        # Track which namespace names we've already inserted mixins for
        inserted_mixins = {} #: Hash[String, bool]

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
              unless inserted_mixins[entry.name]
                entry.mixin_operations.each_with_index do |op, pos|
                  op_type = MIXIN_TYPES[op.class.name] || 0
                  insert_mixin.execute(entry.name, op_type, op.module_name, pos)
                end
                inserted_mixins[entry.name] = true
              end
            end
          end
        end

        # Insert require paths by scanning uris_to_entries for URIs that have require_path
        uris_to_entries.each_value do |entry_list|
          uri = entry_list.first&.uri
          next unless uri

          require_path = uri.require_path
          insert_require_path.execute(require_path, uri.to_s) if require_path
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

    # Prefix search for autocompletion
    #: (String query) -> Array[Array[Entry]]
    def prefix_search(query)
      return [] if query.empty?

      upper = prefix_upper_bound(query)
      rows = @db.execute("SELECT * FROM entries WHERE name >= ? AND name < ?", [query, upper])
      return [] if rows.empty?

      # Group by name, return array of arrays
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
      rows.map { |r| cached_uri(r["uri"]) }
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

    # Update the visibility of an entry in the database
    #: (String name, String uri, Integer start_line, Symbol visibility) -> void
    def update_visibility(name, uri, start_line, visibility)
      vis_int = VISIBILITY_MAP[visibility] || 0
      @db.execute(
        "UPDATE entries SET visibility = ? WHERE name = ? AND uri = ? AND start_line = ?",
        [vis_int, name, uri, start_line],
      )
    end

    # Delete all entries for a URI
    #: (String uri) -> void
    def delete(uri)
      @db.execute("DELETE FROM entries WHERE uri = ?", [uri])
    end

    # Get mixin operations for a namespace
    #: (String entry_name) -> Array[Entry::ModuleOperation]
    def mixin_operations_for(entry_name)
      rows = @db.execute(
        "SELECT * FROM mixin_operations WHERE entry_name = ? ORDER BY position",
        [entry_name],
      )

      rows.map do |row|
        if row["operation_type"] == 0
          Entry::Include.new(row["module_name"])
        else
          Entry::Prepend.new(row["module_name"])
        end
      end
    end

    # Find first unqualified constant match
    #: (String name) -> Array[Entry]?
    def first_unqualified_const(name)
      # Try exact match or ending with ::name
      rows = @db.execute(
        "SELECT * FROM entries WHERE name = ? OR name LIKE ? LIMIT 50",
        [name, "%::#{name}"],
      )
      return materialize_entries(rows) if rows.any?

      # Try ending with name
      rows = @db.execute("SELECT * FROM entries WHERE name LIKE ? LIMIT 50", ["%#{name}"])
      return materialize_entries(rows) if rows.any?

      nil
    end

    # Get all entry names matching a fuzzy query (returns just names for Jaro-Winkler filtering in Ruby)
    #: -> Array[[String, Array[Entry]]]
    def all_entries_with_names
      rows = @db.execute("SELECT * FROM entries")
      rows.group_by { |r| r["name"] }.map { |name, group| [name, materialize_entries(group)] }
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

    #: -> void
    def setup_schema
      @db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS entries (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
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
        CREATE INDEX IF NOT EXISTS idx_entries_uri ON entries(uri);
        CREATE INDEX IF NOT EXISTS idx_entries_owner ON entries(owner_name);

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
          operation_type INTEGER NOT NULL,
          module_name TEXT NOT NULL,
          position INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_mixin_entry ON mixin_operations(entry_name);

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
    end

    #: (SQLite3::Statement stmt, Entry entry) -> Integer
    def insert_single_entry(stmt, entry)
      entry_type = ENTRY_TYPES[entry.class.name] || 0
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

      # Skip eager comment loading — comments are expensive to parse (re-reads each file).
      # They'll be lazily loaded from disk when materialized entries are accessed.
      comments = entry.instance_variable_get(:@comments)

      stmt.execute(
        entry.name,
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

    #: (Array[Hash[String, untyped]] rows) -> Array[Entry]
    def materialize_entries(rows)
      # Collect entry IDs for Method entries to batch-load signatures
      method_ids = []
      rows.each do |row|
        method_ids << row["id"] if row["entry_type"] == ENTRY_TYPES["RubyIndexer::Entry::Method"]
      end

      # Batch load signatures and parameters for all Method entries
      signatures_by_entry = {}
      unless method_ids.empty?
        placeholders = method_ids.map { "?" }.join(",")
        sig_rows = @db.execute(
          "SELECT * FROM signatures WHERE entry_id IN (#{placeholders}) ORDER BY entry_id, position",
          method_ids,
        )
        sig_ids = sig_rows.map { |r| r["id"] }

        params_by_sig = {}
        unless sig_ids.empty?
          param_placeholders = sig_ids.map { "?" }.join(",")
          param_rows = @db.execute(
            "SELECT * FROM parameters WHERE signature_id IN (#{param_placeholders}) ORDER BY signature_id, position",
            sig_ids,
          )
          param_rows.each do |pr|
            (params_by_sig[pr["signature_id"]] ||= []) << pr
          end
        end

        sig_rows.each do |sr|
          sig_params = (params_by_sig[sr["id"]] || []).map { |pr| materialize_parameter(pr) }
          signature = Entry::Signature.new(sig_params)
          (signatures_by_entry[sr["entry_id"]] ||= []) << signature
        end
      end

      rows.map { |row| materialize_single_entry(row, signatures_by_entry) }
    end

    #: (Hash[String, untyped] row, Hash[Integer, Array[Entry::Signature]] signatures_by_entry) -> Entry
    def materialize_single_entry(row, signatures_by_entry)
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

      case entry_type
      when 0 # Module
        nesting = row["nesting"] ? JSON.parse(row["nesting"]) : [row["name"]]
        entry = Entry::Module.new(nesting, uri, location, name_location, comments)
        load_mixin_operations(entry)
        entry
      when 1 # Class
        nesting = row["nesting"] ? JSON.parse(row["nesting"]) : [row["name"]]
        entry = Entry::Class.new(nesting, uri, location, name_location, comments, row["parent_class"])
        load_mixin_operations(entry)
        entry
      when 2 # SingletonClass
        nesting = row["nesting"] ? JSON.parse(row["nesting"]) : [row["name"]]
        entry = Entry::SingletonClass.new(nesting, uri, location, name_location, comments, nil)
        load_mixin_operations(entry)
        entry
      when 3 # Method
        signatures = signatures_by_entry[row["id"]] || []
        Entry::Method.new(row["name"], uri, location, name_location, comments, signatures, visibility, row["owner_name"])
      when 4 # Accessor
        entry = Entry::Accessor.new(row["name"], uri, location, comments, visibility, row["owner_name"])
        entry
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
        # ConstantAlias needs an UnresolvedConstantAlias to construct, but we can create a minimal one
        unresolved = Entry::UnresolvedConstantAlias.new(row["target"], [], row["name"], uri, location, comments)
        Entry::ConstantAlias.new(row["target"], unresolved)
      when 11 # UnresolvedMethodAlias
        Entry::UnresolvedMethodAlias.new(row["name"], row["old_name"], row["owner_name"], uri, location, comments)
      when 12 # MethodAlias — stored as unresolved since target is a live reference
        Entry::UnresolvedMethodAlias.new(row["name"], row["old_name"] || row["name"], row["owner_name"], uri, location, comments)
      else
        Entry::Constant.new(row["name"], uri, location, comments)
      end
    end

    #: (Entry::Namespace entry) -> void
    def load_mixin_operations(entry)
      ops = mixin_operations_for(entry.name)
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
    # "Foo" -> "Fop" (increment last character)
    #: (String prefix) -> String
    def prefix_upper_bound(prefix)
      return prefix if prefix.empty?

      prefix[0..-2] + (prefix[-1].ord + 1).chr(Encoding::UTF_8)
    end

    #: (String uri_string) -> URI::Generic
    def cached_uri(uri_string)
      @uri_cache[uri_string] ||= URI(uri_string)
    end
  end
end
