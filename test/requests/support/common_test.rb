# typed: true
# frozen_string_literal: true

require "test_helper"

module RubyLsp
  class CommonTest < Minitest::Test
    include Requests::Support::Common

    def test_kinds_are_defined_for_every_entry
      index = RubyIndexer::Index.new
      # Use an in-memory store so this test doesn't hit the shared on-disk cache
      index.send(:initialize_sqlite_store!, db_path: ":memory:")
      RubyIndexer::RBSIndexer.new(index).index_ruby_core
      index.send(:flush_sqlite_buffer!)

      entries = index.instance_variable_get(:@sqlite_store).all_entries_with_names.flat_map(&:last)
      entries.each do |entry|
        kind = kind_for_entry(entry)
        refute_equal(kind, Constant::SymbolKind::NULL, "Kind not defined for entry: #{entry.inspect}")
      end
    end
  end
end
