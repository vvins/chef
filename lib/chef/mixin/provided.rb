class Chef
  def providers
    ProviderPriorityMap.instance
  end
  def resources
    ResourcePriorityMap.instance
  end
  def set_resource_priority_array(name, resources, **filters, &block)
    resources.set_priority_array(name, resources, **filters, &block)
  end
  def get_resource_priority_array(name)
    resources.get_priority_array(name)
  end
  def set_provider_priority_array(name, providers, **filters, &block)
    resources.set_priority_array(name, providers, **filters, &block)
  end
  def get_resource_priority_array(name)
    resources.get_priority_array(name)
  end

  class NodeEntry
    #
    # Say whether this Entry supports the given instance or arguments.
    #
    # In general, if not enough information is supplied to make a determination,
    # this methods should return `true`.
    #
    # @param args The arguments that will be passed to handle().
    # @param block The block that will be passed to handle().
    #
    # @return `false` if the handler does not support the arguments given;
    #         `true` otherwise.
    #
    def handles?(*args, &block)
      true
    end

    include Comparable

    #
    # The comparison operator for a handler says whether one handler is
    # *preferred* over another handler. This allows handlers to remain sorted.
    #
    # @param other The other Entry.
    #
    # @return [Integer, nil] - 1 if this handler is preferred over the other handler
    #                        - 0 if neither is preferred over the other
    #                        - -1 if the other handler is preferred over this one
    #                        - nil if preference cannot be determined.
    #                        - if not implemented, always returns nil.
    #
    def <=>(other)
      nil
    end

    #
    # NodeEntries can be added to a NodeMap.  They interact with the NodeMap by
    # being sortable, and by telling the parent whether they are supported on
    # the given node by returning true or false to matches_node?
    #
    # A NodeEntry can match on OS, platform, and other node information.
    #
    class NodeEntry
      #
      # Create a new NodeEntry.
      #
      # @param platform [BlackWhiteList, Array[String], String] The platform or list of
      #          platforms on which this handler runs.
      # @param platform_version [BlackWhiteList, Array[String], String] The platform version or
      #          list of platform versions on which this handler runs.
      # @param platform_family [BlackWhiteList, Array[String], String] The platform family or
      #          list of platform families on which this handler runs.
      # @param os [BlackWhiteList, Array[String], String] The os or list of os's on which this
      #          handler runs.
      # @param node_block [Proc] A custom filter that will be passed `instance.node`
      #          and returns `true` if this handler runs on the given platform.
      #
      def initialize(platform: nil, platform_version: nil, platform_family: nil, os: nil, node_block: nil)
        @node_filters ||= {}
        @node_filters[:platform_version] = black_white_list(platform_version) { |v| Chef::Version::Platform.new(v) }
        @node_filters[:platform] = black_white_list(platform)
        @node_filters[:platform_family] = black_white_list(platform_family)
        @node_filters[:os] = black_white_list(os)
        @node_filters.delete_if { |k, v| v.nil? }
        @node_block = node_block
      end

      #
      # Filters that will be run against the node.
      #
      # @return [Hash[Symbol, BlackWhiteList]] The list of filters
      #
      attr_reader :node_filters

      #
      # A block which will be passed `instance.node`, and returns `true` if this
      # handler will run against the given node.
      #
      # @return [Proc, nil] The block, or `nil` if not specified.
      #
      attr_reader :node_block

      #
      # Order NodeEntries in order of specificity.
      #
      # Entries that specify a "platform", for example, are always preferred
      # over handlers that specify an "os". The order:
      #
      # 1. platform_version
      # 2. platform
      # 3. platform_family
      # 4. os
      # 5. node_block
      #
      # @param other The other NodeEntry.
      #
      # @return [Integer, nil] - 1 if this handler is preferred over the other handler
      #                        - 0 if neither is preferred over the other
      #                        - -1 if the other handler is preferred over this one
      #                        - nil if preference cannot be determined.
      #                        - if not implemented, always returns nil.
      #
      def <=>(other)
        return nil if !other.is_a?(NodeEntry)

        # Things with more specific filters are preferred over things with less
        # specific filters.
        node_filters[:platform_version].nil? <=> other.node_filters[:platform_version].nil? ||
        node_filters[:platform].nil?         <=> other.node_filters[:platform].nil? ||
        node_filters[:platform_family].nil?  <=> other.node_filters[:platform_family].nil? ||
        node_filters[:os].nil?               <=> other.node_filters[:os].nil? ||
        node_block.nil?                      <=> other.node_block.nil?
      end

      #
      # Determines if this handler can handle the given node, by checking
      # node[:os], node[:platform_family], node[:platform] and node[:platform_version]
      # against the relevant node filters, and by calling node_block if it is there.
      #
      # @param node The node to match against.
      #
      def matches_node?(node)
        node_filters.all? { |key, filter| filter === node[key] } &&
        node_block === node
      end
      alias :=== :matches_node?

      protected

      def black_white_list(filter, &block)
        case filter
        when nil, BlackWhiteList
          filter
        else
          WhiteBlacklist.parse(filter, &block)
        end
      end

      def node_block_matches?(node)
        block.call node
      end
    end

    class WhiteBlacklist
      def self.parse(*values, &block)
        # Extract the blacklist (strings starting with !) from the input
        blacklist, whitelist = values.partition { |v| v.is_a?(String) && v.start_with?('!') }
        blacklist = blacklist.map { |v| v[1..-1] }
        return nil if whitelist.empty? && blacklist.empty?
        blacklist.map!(&block) if block
        whitelist.map!(&block) if block
        WhiteBlacklist.new(whitelist, blacklist)
      end

      def initialize(whitelist, blacklist)
        @whitelist = whitelist || []
        @blacklist = blacklist || []
      end

      attr_reader :whitelist
      attr_reader :blacklist

      def ===(value)
        # If any blacklist value matches, we don't match
        return false if blacklist.any? { |v| v === value }

        # If the whitelist is empty, or anything matches, we match.
        whitelist.empty? || whitelist.any? { |v| v == :all || v === value }
      end
    end

    #
    # Entry that runs an action.
    #
    # ```ruby
    # file_handler.resolve(file_resource, :create)
    # # => Chef::Provider::File
    # ```
    #
    class ProviderEntry < NodeEntry
      #
      # Create a new ProviderEntry.
      #
      # @param provider_class [Class] The provider class on which new(resource,
      #          action).run_action will be called.
      # @param resource_class [BlackWhiteList, Array[Class, String], Class, String] The resource
      #          resource classes this provider can run against.  If specified as
      #          strings, the classes will be looked up in the global namespace.
      # @param action [BlackWhiteList, Array[String], String] The action or
      #          actions this handler can run.
      # @param node_filters The filters to pass to NodeMatchEntry
      #
      def initialize(provider_class, resource_class: nil, action: nil, **node_filters)
        super(**node_filters)
        @resource_class = resource_class
        @action = black_white_list(action) { |action| action.to_sym}
      end

      #
      # The provider class that will be instantiated to run the action.
      #
      # @return [Class] The provider class.
      #
      attr_reader :provider_class

      #
      # The classes of resource against which this handler will run.
      #
      # @return [BlackWhiteList[Class], nil] The list of classes, or `nil` if not specified.
      #
      attr_reader :resource_class

      #
      # The actions this handler can run.
      #
      # @return [BlackWhiteList[String], nil] The list of actions, or `nil` if not specified.
      #
      attr_reader :action

      #
      # Orders ActionRunners by the specificity of their filters.
      #
      # Entries that specify a "platform", for example, are always preferred
      # over handlers that specify an "os". The order:
      #
      # 1. action
      # 2. resource_class
      # 3. provider_class implements supports?
      # 4. platform_version
      # 5. platform
      # 6. platform_family
      # 7. os
      # 8. node_block
      # 9. provider_class implements provides?
      #
      # @param other The other ActionEntry.
      #
      # @return [Integer, nil] - 1 if this handler is preferred over the other handler
      #                        - 0 if neither is preferred over the other
      #                        - -1 if the other handler is preferred over this one
      #                        - nil if preference cannot be determined.
      #                        - if not implemented, always returns nil.
      #
      def <=>(other)
        return super if !other.is_a?(ProviderEntry)

        action.nil?           <=> other.action.nil? ||
        resource_classes.nil? <=> other.resource_class.nil? ||
        implements_supports?  <=> other.implements_supports? ||
        super ||
        implements_provides?  <=> other.implements_provides?
      end

      #
      # Whether provider_class implements provides?
      #
      # @return [Boolean] true if the provider_class implements provides?
      #
      def implements_provides?
        provider_class.method(:provides?).owner != Chef::Provider
      end

      #
      # Whether provider_class implements supports?
      #
      # @return [Boolean] true if the provider_class implements supports?
      #
      def implements_supports?
        provider_class.method(:supports?).owner != Chef::Provider
      end

      #
      # Whether the provider_class handles the given instance and action
      #
      # @param resource The resource we want to run the action on
      #
      def runs_action?(resource, action)
        black_white_list_matches?(resource_class, resource.class) &&
        black_white_list_matches?(self.action, action) &&
        matches_node?(resource.node) &&
        (implements_provides? && provider_class.provides?(resource.node, resource)) &&
        (implements_supports? && provider_class.supports?(resource, action)
      end
    end

    #
    # Entry that declares a resource.
    #
    # ```ruby
    # Chef.resources.resolve(my_recipe, :file, '/x.txt') do
    #   content 'Hello World'
    # end
    # # => Chef::Resource::File
    # ```
    #
    class ResourceEntry
      include NodeEntry

      attr_reader :name
      attr_reader :resource_class

      #
      # Create a new ResourceEntry
      #
      # @param resource_class [Class] The resource class that will be resolved
      #          if handles? returns true.
      # @param node_filters The filters to pass to NodeMatchEntry
      #
      def initialize(name, resource_class, **node_filters)
        super(**node_filters)
        @name = name
        @resource_class = resource_class
      end

      #
      # Whether resource_class implements provides?
      #
      # @return [Boolean] true if the resource_class implements provides?
      #
      def implements_provides?
        provider_class.method(:provides?).owner != Chef::Resource
      end

      #
      # Orders ResourceEntries by the specificity of their filters.
      #
      # Entries that specify a "platform", for example, are always preferred
      # over handlers that specify an "os". The order:
      #
      # 1. platform_version
      # 2. platform
      # 3. platform_family
      # 4. os
      # 5. node_block
      # 6. resource_class implements provides?
      #
      # @param other The other Entry.
      #
      # @return [Integer, nil] - 1 if this handler is preferred over the other handler
      #                        - 0 if neither is preferred over the other
      #                        - -1 if the other handler is preferred over this one
      #                        - nil if preference cannot be determined.
      #                        - if not implemented, always returns nil.
      #
      def <=>(other)
        return super if !other.is_a?(ResourceEntry)

        super ||
        implements_provides? <=> other.implements_provides?
      end

      def builds_resource?(recipe, *args, &block)
        matches_node?(recipe.node) &&
        (implements_provides? && resource_class.provides?(resource.node, resource))
      end
    end

    class NodeMap
      def register_handler(key, handler)
        map[key] ||= []
        # Insert at the first spot where we are preferred over the other
        insert_at = map[key].index { |other| handler >= other } || 0
        map[key].insert(insert_at, handler)
      end

      def resolve(key, *args, &block)
        candidates(*args, &block).first
      end

      def candidates(key, *args, &block)
        return [] unless map[key]
        map[key].select { |handler| handler.handles?(*args, &block) }
      end

      def each_handler(key=nil, &block)
        if key
          (map[key] || []).each(&block)
        else
          map.each_value.flat_map(&block)
        end
      end

      def handlers(key=nil)
        key ? (map[key] || []) : map.values.flatten(1)
      end

      def clear
        @map.clear
      end

      # @api private
      def resolve_for_node(node, key)
        candidates(node, key).first
      end

      # @api private
      def candidates_for_node(node, key)
        return [] unless map[key]
        map[key].select { |handler| handler.handles_node?(node) }
      end

      protected

      def map
        @map ||= {}
      end
    end

    class ResourceRegistry < EntryRegistry
      def register(name, resource_class, **filter)
        register_handler(name, ResourceEntry.new(name, resource_class, filter))
      end
    end

    class ProviderRegistry < EntryRegistry
      def register(name, provider_class, **filter)
        register_handler(name, ProviderEntry.new(provider_class, filter))
      end

      def resolve(resource, action)
        super(resource.resource_name, resource, action)
      end

      def candidates(resource, action)
        super(resource.resource_name, resource, action)
      end
    end
  end
end

# Implementation of existing things
class Chef::Resource
  def provider_for_action(action)
    Chef.providers.resolve(self, action)
  end

  def self.resource_for_node(node, name)
    Chef.resources.resolve_for_node(node, name)
  end

  def provider(name)
    Chef.providers.resolve_for_node(node, name)
  end
end

#
# Backcompat / deprecate
#
class Chef

  class Chef::Resource
  end

  class Chef::ProviderResolver < FilteredMap
    def initialize(node, resource, action=nil)
      super(Chef.providers, node: node, resource: resource, action: action)
    end

    def node
      defaults[:node]
    end
    def resource
      defaults[:resource]
    end
    def action
      defaults[:action]
    end
  end

  class Chef::ResourceResolver < FilteredMap
    def initialize(node, name)
      super(Chef.resources, node: node, name: name)
    end

    def node
      defaults[:node]
    end
    def resource
      defaults[:name]
    end
  end

  class Chef::PriorityMap
    def initialize(handler_registry)
      @handler_registry = handler_registry
    end

    def set_priority_array(resource_name, priority_array, **filter, &block)
      Array(priority_array).reverse_each do |handler_class|
        handler_registry.register(handler_class, **filter, &block)
      end
    end

    def get_priority_array(node, resource_name)
      handler_registry.candidates_for_node(node, resource_name)
    end
  end

  class Chef::ProviderPriorityMap < Chef::PriorityMap
    def self.instance
      new(Chef.providers)
    end
  end

  class Chef::ResourcePriorityMap < Chef::PriorityMap
    def self.instance
      new(Chef.resources)
    end
  end

  class NodeMap
    # TODO Do we need to change it?  Can people live without any global ones?
  end
end
