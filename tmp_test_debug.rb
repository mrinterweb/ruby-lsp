require "ruby_indexer/ruby_indexer"
require "ruby_indexer/test/test_case"

index = RubyIndexer::Index.new
index.send(:initialize_sqlite_store!, db_path: ":memory:")
RubyIndexer::RBSIndexer.new(index).index_ruby_core
index.send(:flush_sqlite_buffer!)

# Register the enhancement
Class.new(RubyIndexer::Enhancement) do
  def on_call_node_enter(call_node)
    owner = @listener.current_owner
    return unless owner
    return unless call_node.name == :extend

    arguments = call_node.arguments&.arguments
    return unless arguments

    arguments.each do |node|
      next unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      module_name = node.full_name
      next unless module_name == "ActiveSupport::Concern"

      @listener.register_included_hook do |idx, base|
        class_methods_name = "#{owner.name}::ClassMethods"
        if idx.indexed?(class_methods_name)
          puts "Hook: adding ClassMethods to singleton of #{base.name}"
          singleton = idx.existing_or_new_singleton_class(base.name)
          puts "  singleton from buffer? #{idx.instance_variable_get(:@sqlite_buffer).include?(singleton)}"
          puts "  singleton object_id: #{singleton.object_id}"
          singleton.mixin_operations << RubyIndexer::Entry::Include.new(class_methods_name)
          puts "  singleton mixins: #{singleton.mixin_operations.map(&:module_name)}"
        else
          puts "Hook: #{class_methods_name} not indexed"
        end
      end
    rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError,
           Prism::ConstantPathNode::MissingNodesInConstantPathError
    end
  end
end

index.index_single(URI::Generic.from_path(path: "/fake/path/foo.rb"), <<~RUBY)
  module ActiveSupport
    module Concern
    end
  end

  module ActiveRecord
    module Associations
      extend ActiveSupport::Concern

      module ClassMethods
        def belongs_to(something); end
      end
    end

    class Base
      include Associations
    end
  end

  class User < ActiveRecord::Base
  end
RUBY

index.send(:flush_sqlite_buffer!)

puts "Before linearization:"
s = index["ActiveRecord::Base::<Class:Base>"]
puts "Base singleton exists? #{!s.nil?}"
if s
  puts "Base singleton mixins: #{s.first.mixin_operations.map(&:module_name)}"
end

ancestors = index.linearized_ancestors_of("User::<Class:User>")
puts "\nUser singleton ancestors: #{ancestors}"

puts "\nAfter linearization - check singleton again:"
s2 = index["ActiveRecord::Base::<Class:Base>"]
if s2
  puts "Base singleton mixins: #{s2.first.mixin_operations.map(&:module_name)}"
end
