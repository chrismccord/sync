module Sync
  module Model

    def self.enabled?
      Thread.current["model_sync_enabled"]
    end

    def self.context
      Thread.current["model_sync_context"]
    end

    def self.enable!(context = nil)
      Thread.current["model_sync_enabled"] = true
      Thread.current["model_sync_context"] = context
    end

    def self.disable!
      Thread.current["model_sync_enabled"] = false
      Thread.current["model_sync_context"] = nil
    end

    def self.enable(context = nil)
      enable!(context)
      yield
    ensure
      disable!
    end

    module ClassMethods
      attr_accessor :sync_default_scope, :sync_scope_definitions

      # Set up automatic syncing of partials when creating, deleting and update of records
      #
      def sync(*actions)
        include ModelActions
        
        #attr_accessor :sync_actions
        
        if actions.last.is_a? Hash
          @sync_default_scope = actions.last.fetch :scope
        end
        @sync_scope_definitions ||= {}
        actions = [:create, :update, :destroy] if actions.include? :all
        actions.flatten!

        if actions.include? :create
          before_create  :prepare_sync_actions,               if: -> { Sync::Model.enabled? }
          after_create   :prepare_sync_create, on: :create,   if: -> { Sync::Model.enabled? }
        end
        
        if actions.include? :update
          before_update  :prepare_sync_actions,               if: -> { Sync::Model.enabled? }
          before_update  :store_state_before_update,          if: -> { Sync::Model.enabled? }
          after_update   :prepare_sync_update, on: :update,   if: -> { Sync::Model.enabled? }
        end
        
        if actions.include? :destroy
          before_destroy :prepare_sync_actions,               if: -> { Sync::Model.enabled? }
          after_destroy   :prepare_sync_destroy, on: :destroy, if: -> { Sync::Model.enabled? }
        end

        after_commit :publish_sync_actions,                   if: -> { Sync::Model.enabled? }

      end

      # Set up a sync scope for the model defining a set of records to be updated via sync
      #
      # name - The name of the scope
      # lambda - A lambda defining the scope.
      #    Has to return an ActiveRecord::Relation.
      #
      # You can define the lambda with arguments (see examples). 
      # Note that the naming of the parameters is very important. Only use names of
      # methods or ActiveRecord attributes defined on the model (e.g. user_id). 
      # This way sync will be able to pass changed records to the lambda and track
      # changes to the scope.
      #
      # Example:
      #
      #   class Todo < ActiveRecord::Base
      #     belongs_to :user
      #     belongs_to :project
      #     scope :incomplete, -> { where(complete: false) }
      #
      #     sync :all
      #
      #     sync_scope :complete, -> { where(complete: true) }
      #     sync_scope :by_project, ->(project_id) { where(project_id: project_id) }
      #     sync_scope :my_incomplete_todos, ->(user) { incomplete.where(user_id: user.id) }
      #   end
      #
      # To subscribe to these scopes you would put these lines into your views:
      #
      #   <%= sync partial: "todo", Todo.complete, scope: Todo.complete %>
      #   <%= sync_new partial: "todo", Todo.new, scope: Todo.complete %>
      #
      # Or for my_incomplete_todos:
      #
      #   <%= sync partial: "todo", Todo.my_incomplete_todos(current_user), 
      #            scope: Todo.my_incomplete_todos(current_user) %>
      #   <%= sync_new partial: "todo", Todo.new, scope: Todo.my_incomplete_todos(current_user) %>
      # 
      # Now when a record changes sync will use the names of the lambda parameters 
      # (project_id and user), get the corresponding attributes from the record (project_id column or
      # user association) and pass it to the lambda. This way sync can identify if a record
      # has been added or removed from a scope and will then publish the changes to subscribers
      # on all scoped channels.
      #
      # Beware that chaining of sync scopes in the view is currently not possible.
      # So the following example would raise an exception:
      #
      #   <%= sync_new partial: "todo", Todo.new, scope: Todo.mine(current_user).incomplete %>
      #
      # To work around this just create an explicit sync_scope for your problem:
      # 
      #   sync_scope :my_incomplete_todos, ->(user) { incomplete.mine(current_user) }
      #
      # And in the view:
      #
      #   <%= sync_new partial: "todo", Todo.new, scope: Todo.my_incomplete_todos(current_user) %>
      #
      def sync_scope(name, lambda)
        if self.respond_to?(name)
          raise ArgumentError, "invalid scope name '#{name}'. Already defined on #{self.name}"
        end
        
        @sync_scope_definitions[name] = Sync::ScopeDefinition.new(self, name, lambda)
        
        singleton_class.send(:define_method, name) do |*args|
          Sync::Scope.new_from_args(@sync_scope_definitions[name], args)
        end        
      end
      
    end

    module ModelActions
      def sync_default_scope
        return nil unless self.class.sync_default_scope
        send self.class.sync_default_scope
      end
      
      def sync_actions
        @sync_actions
      end

      def sync_render_context
        Sync::Model.context || super
      end
      
      def prepare_sync_actions
        @sync_actions = []
      end

      def prepare_sync_create
        @sync_actions.push Action.new(self, :new, scope: sync_default_scope)
        @sync_actions.push Action.new(sync_default_scope.reload, :update) if sync_default_scope
        
        sync_scope_definitions.each do |definition|
          @sync_actions.push Action.new(self, :new, scope: Sync::Scope.new_from_model(definition, self), default_scope: sync_default_scope)
        end
      end

      def prepare_sync_update
        if sync_default_scope
          @sync_actions.push Action.new([self, sync_default_scope.reload], :update)
        else
          @sync_actions.push Action.new(self, :update)
        end

        sync_scope_definitions.each do |definition|
          prepare_sync_update_scope(definition)
        end
      end

      def prepare_sync_destroy        
        @sync_actions.push Action.new(self, :destroy)
        @sync_actions.push Action.new(sync_default_scope.reload, :update) if sync_default_scope
        
        sync_scope_definitions.each do |definition|
          @sync_actions.push Action.new(self, :destroy, scope: Sync::Scope.new_from_model(definition, self), default_scope: sync_default_scope)
        end
      end

      private

      # Publishes updates on the record to subscribers on the sync scope defined by
      # the passed sync scope definition.
      #
      # It compares the state of the record in context of the sync scope before and
      # after the update. If the record has been added to a scope, it publishes a 
      # new partial to the subscribers of that scope. It also sends a destroy action
      # to subscribers of the scope, if the record has been removed from it.
      #
      def prepare_sync_update_scope(definition)
        record_before_update = @record_before_update
        record_after_update = self

        scope_before_update = @scopes_before_update[definition.name][:scope]
        scope_after_update = Sync::Scope.new_from_model(definition, record_after_update)

        old_record_in_old_scope = @scopes_before_update[definition.name][:contains_record]
        old_record_in_new_scope = scope_after_update.contains?(record_before_update)

        new_record_in_new_scope = scope_after_update.contains?(record_after_update)
        new_record_in_old_scope = scope_before_update.contains?(record_after_update)

        # Update/Destroy existing partials of listeners on the scope before the update
        if scope_before_update.valid?
          if old_record_in_old_scope && !new_record_in_old_scope
            @sync_actions.push Action.new(record_before_update, :destroy, scope: scope_before_update, default_scope: sync_default_scope)
          elsif old_record_in_new_scope
            @sync_actions.push Action.new(record_after_update, :update, scope: scope_before_update, default_scope: sync_default_scope)
          end
        end

        # Publish new partials to listeners on this new (changed) scope
        if scope_after_update.valid?
          if new_record_in_new_scope && !new_record_in_old_scope
            @sync_actions.push Action.new(record_after_update, :new, scope: scope_after_update, default_scope: sync_default_scope)
          end
        end
      end
      
      def publish_sync_actions
        @sync_actions.each(&:perform)
      end
      
      def sync_scope_definitions
        self.class.sync_scope_definitions.values
      end

      # Stores the current state of the record and of all sync relations in an instance 
      # variable BEFORE the update command to later be able to check if the record 
      # has been added/removed from sync scopes.
      #
      # Uses ActiveModel::Dirty to track attribute changes
      # (triggered by AR Callback before_update)
      #
      def store_state_before_update
        record = self.class.new(self.attributes)
        record.attributes = self.changed_attributes
        @record_before_update = record
        
        @scopes_before_update = {}
        sync_scope_definitions.each do |definition|
          scope = Sync::Scope.new_from_model(definition, record)
          @scopes_before_update[definition.name] = { 
            scope: scope, 
            contains_record: scope.contains?(record) 
          }
        end
      end

      
    end
  end
end