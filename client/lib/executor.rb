require 'pty'
$VERBOSE=nil

['commons', 'ys_s3', 'storage', 'git', 'sync', 'storage_sync'].each { |file_name| require file_name }

def spawn_using_pty feedback, cmd, *args
  PTY.spawn(cmd, *args) do |r,w,cid|
    begin
      loop do
        begin
          l = r.readpartial(1024)
        rescue EOFError
          break
        end
        feedback.command_output l
      end
      begin
        # try to invoke waitpid() before the signal handler does it
        return Process::waitpid2(cid)[1].exitstatus
      rescue Errno::ECHILD    
        # the signal handler managed to call waitpid() first;
        # PTY::ChildExited will be delivered pretty soon, so just wait for it
        sleep 1
      end
    rescue PTY::ChildExited => e
      return e.status.exitstatus
    end
    # should never happen
    raise "Internal error: failure to obtain exit code of a process"
  end
end

def spawn_using_system feedback, cmd, *args
  if system(cmd, *args) then 0 else $?.exitstatus end
end

def invoke feedback, cmd, *args
  args = [''] if args.empty?
  msg = "INVOKE #{cmd}#{args.collect {|a| "\n  ARG #{a}"}.join('')}"
  feedback.info msg

  begin
    exit_code = spawn_using_pty(feedback, cmd, *args)
  rescue NotImplementedError
    feedback.info "Falling back to system() because forking is not supported."
    exit_code = spawn_using_system(feedback, cmd, *args)
  end
  
  if exit_code != 0
    basename = File.basename(cmd)
    summary = case exit_code
        when 127 then "'#{basename}' not found"
        else          "'#{basename}' failed with code #{exit_code}"
    end
    raise "#{summary}\n#{msg}"
  end
end

def mv_merge src, dst
  if File.directory?(src) && File.directory?(dst)
    Dir.open(src) do |dir|
      while entry = dir.read
        next if entry == '.' or entry == '..'
        mv_merge "#{src}/#{entry}", "#{dst}/#{entry}"
      end
    end
  else
    FileUtils.mkdir_p File.dirname(dst)
    FileUtils.mv src, dst
  end
end

def cp_merge src, dst
  if File.directory?(src) && File.directory?(dst)
    Dir.open(src) do |dir|
      while entry = dir.read
        next if entry == '.' or entry == '..'
        cp_merge "#{src}/#{entry}", "#{dst}/#{entry}"
      end
    end
  else
    FileUtils.mkdir_p File.dirname(dst)
    FileUtils.cp_r src, dst
  end
end

def list_entries(path, result = [])
  Dir.open(path) do |dir|
    while entry = dir.read
      next if entry == '.' or entry == '..'
      result << entry
    end
  end
  return result
end

def list_entries_recursively(path, result = [])
  Dir.open(path) do |dir|
    while entry = dir.read
      next if entry == '.' or entry == '..'
      child = File.join(path, entry)
      result << child
      list_entries_recursively child, result if File.directory? child
    end
  end
  return result
end

class BuildScriptError < StandardError
end

class ErrorneousRequireError < StandardError
  
  attr_reader :name
  
  def initialize name
    @name = name
  end
end

class UnresolvedNameError < StandardError
end

class PostponeResolutionError < StandardError
  
  attr_reader :stage
  
  def initialize stage
    @stage = stage
  end
  
end

class RepositoryOverride
  
  attr_reader :local_dir
  
  def initialize repos_kind, repos, branch, local_dir
    @repos_kind = repos_kind
    @repos = repos
    @branch = branch
    @local_dir = local_dir
  end
  
  def matches? repos
    !! repos.locations.find { |loc| loc.url == @repos }
  end
  
end

class Context
  
  def initialize
    @output_items = {}
  end
  
  def mark_for_output! item
    @output_items[item.name] = true
  end
  
  def marked_for_output? item
    @output_items[item.name] || false
  end
  
end

class Executor
  
  attr_reader :project_dir, :local_store
  attr_reader :variables, :repositories, :items, :stores
  
  def initialize builder_name, feedback
    @builder_name = builder_name # used to make create a local store name
    @feedback = feedback
    @variables = {}
    @repositories = {}
    @stores = {}
    @items = {}
    @aliases = {}
    @errorneous = {}
    @postponed = {}
    @preferred_locations = {}
    @build_error = nil
    @item_fetching_allowed = false
    @references_expansion_enabled = false
    if File.directory? "/tmp" and not is_windows?
      @storage_dir = "/tmp/ysbuilder-#{builder_name}" 
    else
      @storage_dir = File.join(File.tmpdir, "ysbuilder-#{builder_name}")
    end
    load_alternates_file
    
    @actions = {}
    ObjectSpace.each_object(Class) do |klass|
      if klass.superclass == Command
        klass.command_names.each do |name|
          @actions[name] = klass
        end
      end
    end
  end
  
  def name_errorneous! name
    @errorneous[name] = true
    @feedback.info "Name [#{name}] has been marked as errorneous, any further commands mentioning it will be ignored."
  end
  
  def name_errorneous? name
    @errorneous[name] || false
  end
  
  def new_command command, args, data_lines, lineno
    (@actions[command.upcase] or raise BuildScriptError, "Unknown command #{command}(#{args.join(', ')})").new(self, data_lines, args, lineno)
  end
  
  def create_report
    report = []
    @stores.values.each do |store|
      report << ['STORE', store.name, store.tags.join(',').subst_empty('-'), store.description.subst_empty('-')]
    end
    @local_store.all_items.each do |item|
      stores = @local_store.stores_for(item)
      unless stores.empty?
        report << ['ITEM', "#{item.kind}", item.name, item.tags.join(',').subst_empty('-'), item.description.subst_empty('-')]
        stores.each do |store|
          report << ['INSTORE', store.name]
          
          locations_by_kind = {}
          store.locations.each { |location| locations_by_kind[location.kind] ||= location if location.public? }
          locations_by_kind.values.each do |location|
            report << ['ACCESS', "#{location.kind}", location.tags.join(',').subst_empty('-'), location.describe_location_of(item)]
          end
        end
      end
    end
    return report
  end
  
  def set_project! permalink, name
    @variables['project'] = permalink
    @variables['project-name'] = name
    ver = @variables['ver'] or raise 'SET ver must have been executed before PROJECT'
    
    company = (@variables['company-permalink'] ||= '')
    company_name = (@variables['company'] || '')
    full_project = (@variables['full-project'] ||= if company.empty? then "#{permalink}" else "#{company}-#{permalink}" end)
    full_project_name = (@variables['full-project-name'] ||= if company_name.empty? then "#{name}" else "#{company_name} #{name}" end)
    @variables['build-files-prefix'] = "#{full_project}-#{ver}"
    @variables['build-descr-prefix'] = "#{full_project_name} #{ver}"
    
    @project_dir = File.join(@storage_dir, permalink)
    FileUtils.mkdir_p(@project_dir)
    
    @local_store = LocalStore.new(@builder_name, [], File.join(@project_dir, 'localitems'))
    @stores[@local_store.name] = @local_store
  end
  
  def define_repository name
    @repositories[name] ||= yield
  end
  
  def redefine_repository! name, repos
    @repositories[name] = repos
  end
  
  def configure_repository! name
    @repositories[name].set_preferred_location! @preferred_locations[name] if @preferred_locations[name]
  end
  
  def define_store name
    @stores[name] ||= yield
  end
  
  def override_for repos
    @overrides.find { |o| o.matches? repos }
  end
  
  def resolve_alias name
    @aliases[name] || name
  end
  
  def define_item! item
    name = item.name
    raise "Duplicate item #{item}" unless @items[name].nil?
    @items[name] = item
    @feedback.info "new item defined: [#{item.name}]"
    item
  end
  
  def expand_per_build_name name
    name.gsub('%', resolve_variable('build-files-prefix'))
  end
  
  def expand_per_build_descr descr
    descr.gsub('%', resolve_variable('build-descr-prefix'))
  end
  
  def define_default_item! kind, alias_name, name, tags, description
    name = resolve_alias(name)
    define_alias alias_name, name unless alias_name =~ /^-?$/
    define_item! @local_store.new_item(kind, name, tags, description)
  end
  
  def define_variable name, value
    @variables[name] = value
  end
  
  def find_repository name
    @repositories[name] or raise BuildScriptError, "Repository #{name} not found"
  end
  
  def find_store name
    @stores[name] or raise BuildScriptError, "Store #{name} not found"
  end
  
  def find_item name
    @items[name] or raise BuildScriptError, "Item #{name} not found"
  end
  
  def allow_fetching_items!
    @item_fetching_allowed = true
  end
  
  def start_stage! stage
    @at_least_one_finished_on_this_stage = false
    @repeat_this_stage = false
  end
  
  def enable_references_expansion!
    @references_expansion_enabled = true
  end

  def execute_command! stage, command
    return if command.errorneous?
    return unless command.would_execute_on? stage
    begin
      command.inputs.each { |name| raise ErrorneousRequireError.new(name) if name_errorneous?(name) }

      if @references_expansion_enabled
        loop do
          refs = command.collect_refs
          break if refs.empty?
      
          values = {}
          refs.each { |ref| values[ref.name] = resolve_ref(ref) }
          command.subst_refs! values
        end
      else
        return unless command.collect_refs.empty?
      end
    
      command.execute! stage, self, @feedback
      @at_least_one_finished_on_this_stage = true
    rescue PostponeResolutionError => e
      if stage == e.stage
        @repeat_this_stage = true
        @feedback.info "#{command} will be repeated on stage #{stage}"
      else
        command.postpone! stage, e.stage
        @feedback.info "#{command} postponed until stage #{e.stage}"
      end
    rescue ErrorneousRequireError => e
      @feedback.error "#{command} ignored because it requires '#{e.name}', but generation of '#{e.name}' has failed"
      command.errorneous! e
    rescue StandardError => e
      @feedback.error "#{command}: error - #{e}"
      command.errorneous! e
      @build_error ||= e
    end
  end
  
  def finish_stage! stage
    throw :repeat_stage, true if @repeat_this_stage
  end
  
  def determine_inputs_and_outputs! commands
    context = Context.new
    commands.each do |command|
      next if command.errorneous?
      begin
        refs = command.collect_refs
        refs.each do |ref|
          next if @variables[ref.name] # not interested in variables
        
          name = resolve_alias(ref.name)
          item = @items[name] or raise ExecutionError.new("Undefined variable or item [#{ref.name}]")
          next unless item.in_local_store?
          
          unless ref.tagged_with?('nodep')
            name = resolve_alias(ref.name)
            if ref.tagged_with?('alter')
              command.add_input! name
              command.add_output! name
            elsif context.marked_for_output? item
              command.add_input! name
            else
              context.mark_for_output! item
              command.add_output! name
            end
          end
        end
        command.determine_inputs_and_outputs! self, @feedback
      rescue StandardError => e
        @feedback.error "#{command}: error determining inputs and outputs - #{e}"
        command.errorneous! e
      end
    end
  end
  
  def finish_build!
    raise @build_error if @build_error
  end

  def define_alias name, item_name
    @aliases[name] = resolve_alias(item_name)
  end
  
  def resolve_variable name
    @variables[name] or raise ExecutionError.new("Undefined variable [#{name}]")
  end
  
  def resolve_optional_variable name, default = nil
    @variables[name] or default
  end
  
  def set_preferred_location repo_name, reason, location_name
    @preferred_locations[repo_name] = location_name
    @repositories[repo_name].set_preferred_location! location_name if @repositories[repo_name]
  end
  
private

  def load_alternates_file
    @overrides = []
    file_name = File.expand_path("~/.ysbuilder_overrides")
    begin
      File.read(file_name).split("\n").each do |line|
        next if line =~ /^\s*(#|$)/
        repos_kind, repos, branch, alt = line.split("\t")
        @overrides << RepositoryOverride.new(repos_kind, repos, branch, File.expand_path(alt))
      end
    rescue SystemCallError
    end
  end
  
  def get_item ref
    name = resolve_alias(ref.name)
    item = @items[name] or return nil
    if item.in_local_store? && !item.used?
      item.bring_parent_to_life!
      item.obliterate_completely! unless ref.tagged_with?('keep')
      item.bring_me_to_life! if ref.tagged_with?('mkdir')
    end
    return item.fetch_locally(@feedback) if item.is_fetching_very_fast?
    @feedback.action "Fetching item #{item.name}..."
    item.fetch_locally @feedback
  end
  
  def resolve_ref ref
    raise ErrorneousRequireError.new(ref.name) if name_errorneous?(ref.name)
    raise PostponeResolutionError.new(@postponed[ref.name]) if @postponed[ref.name]
    if @item_fetching_allowed
      @variables[ref.name] or get_item(ref) or raise ExecutionError.new("Undefined variable or item [#{ref.name}]")
    else
      @variables[ref.name] or raise PostponeResolutionError.new(:main)
    end
  end
  
end

class Ref
  
  attr_reader :name, :tags
  
  def initialize name, tags
    @name = name
    @tags = tags
  end
  
  def tagged_with? tag
    @tags.include? tag
  end
  
end

class Command
  
  PATTERN = /\[([^\[\]<]+)(?:<([^>]*)>)?\]/
  
  attr_reader :inputs
  
  def is_long?; true; end
  
  def self.acts_as_short
    define_method(:is_long?) { false }
  end
  
  def self.command_names
    return [const_get('KEYWORD')] if const_defined?('KEYWORD')
    raise "No name could be inferred for command #{self.name}" unless self.name =~ /^(.*)Command$/
    [$1.upcase, $1.gsub(/([a-z])([A-Z])/) { |_| "#{$1}-#{$2}" }.upcase]
  end
  
  def initialize executor, data_lines, args, lineno
    @executor = executor
    @data_lines = data_lines
    @raw_args = args
    @lineno = lineno
    @values = {}
    @postpones = {}
    @inputs = []
    @outputs = []
    @errorneous = false
  end
  
  def determine_inputs_and_outputs! executor, feedback
  end
  
  def add_input! name
    puts "#{self} << input #{name}"
    @inputs << name
  end
  
  def add_output! name
    puts "#{self} << output #{name}"
    @outputs << name
  end
  
  def dump_inputs_and_outputs
    puts "#{self} << #{@inputs.join(',')}"
    puts "#{self.to_s.gsub(/./, ' ')} >> #{@outputs.join(',')}"
  end
  
  def errorneous! error
    @errorneous = true
    @outputs.each { |name| @executor.name_errorneous! name }
  end
  
  def errorneous?
    @errorneous
  end
  
  def collect_refs
    (@raw_args.collect { |arg| collect_refs_in(arg) } +
      @data_lines.collect { |line| line.collect { |arg| collect_refs_in(arg) } }).flatten.uniq
  end
  
  def subst_refs! values
    @raw_args.collect! { |arg| subst_refs_in(arg, values) }
    @data_lines.each { |line|
      line.collect! { |arg| subst_refs_in(arg, values) }
    }
  end
  
  def to_s
    "#{command_name}:#{@lineno}"
  end
  
  def would_execute_on? stage
    @postpones[stage] || self.respond_to?(stage_selector(stage))
  end
  
  def execute! stage, executor, feedback
    @executor = executor
    @feedback = feedback
    
    @feedback.start_command self, is_long?
    (@postpones[stage] || []).uniq.each do |as_stage|
      forward_to_handler! nil, stage_selector(as_stage), @raw_args
    end
    forward_to_handler! nil, stage_selector(stage), @raw_args if self.respond_to?(stage_selector(stage))
  end
  
  def postpone! act_as_stage, on_stage
    (@postpones[on_stage] ||= []) << act_as_stage
  end
  
  def stage_selector stage
    case stage when :main then :do_execute! else :"do_execute_stage_#{stage}!" end
  end
  
  def defined_names
    []
  end
  
private

  def execute_subcommands! *other_args
    @data_lines.each do |subcommand, *subargs|
      id = :"do_#{subcommand.downcase}!"
      self.method(id) or raise BuildScriptError, "Undefined subcommand #{subcommand}"
      forward_to_handler! subcommand, id, subargs, *other_args
    end 
  end

  def forward_to_handler! subcommand, id, args, *prepend_args
    descr = "Command #{command_name}"
    descr = "Subcommand #{subcommand} of command #{command_name}" if subcommand
    
    arity = self.method(id).arity
    if arity > 0
      raise BuildScriptError, "#{descr} expects #{arity-prepend_args.size} arguments, #{args.size} given" unless args.size == arity - prepend_args.size
    elsif arity < -1
      min_args = -arity - 1
      raise BuildScriptError, "#{descr} expects at least #{min_args-prepend_args.size} arguments, #{args.size} given" unless args.size >= min_args - prepend_args.size
    end
    self.send(id, *(prepend_args + args))
  end

  def collect_refs_in string, pattern=PATTERN
    result = []
    string.scan(pattern) { |ref, tags| result << Ref.new(ref, parse_tags(tags)) }
    return result
  end

  def subst_refs_in string, values, pattern=PATTERN
    @values.merge! values
    string.gsub(pattern) { |_| values[$1] }
    #     tags = parse_tags($2)
    #     additional_variables[$1] or @variables[$1] or get_item($1, tags) or raise ExecutionError.new("Undefined variable or item [#{$1}]")
    #   }
    #   return result if result == value
    #   value = result
    # end
  end
  
  def parse_tags tags_str
    tags_str = (tags_str || '').strip
    return case tags_str when '', '-' then [] else tags_str.split(/\s*,\s*/) end
  end
  
  def command_name
    self.class.command_names.first
  end
  
  def invoke! *args
    invoke @feedback, *args
  end
  
end

class SayCommand < Command
  
  def do_execute! text
    @feedback.info "Saying #{text}."
    invoke! 'say', text
  end
  
end

class ProjectCommand < Command
  
  acts_as_short
  
  def do_execute_stage_project! permalink, name
    @executor.set_project! permalink, name
  end
  
  def defined_names
    ['project', 'project-name']
  end
  
end

class SetCommand < Command
  
  acts_as_short
  
  
  def do_execute_stage_pure_set! name, value
    @executor.define_variable name, value
  end
  
  def do_execute_stage_set! name, value
    @executor.define_variable name, value
  end
  
  def to_s
    "SET:#{@lineno} #{@raw_args[0]}"
  end

  def defined_names
    name = @raw_args[0]
    raise UnresolvedNameError if name =~ %r!/!
    [name]
  end
  
end

module InvokeCommands
  
  def execute_invoke! app, *args
    for name, value in @executor.variables
      ENV[name] = value
    end
    @args = args
    execute_subcommands!
    invoke! app, *@args
  end
  
  def do_arg! arg
    @args.push arg
  end
  
  def do_args! *args
    @args.push *args
  end
  
  def do_dep! *args
  end

end

class InvokeCommand < Command
  
  include InvokeCommands
  
  def do_execute! app, *args
    execute_invoke! app, *args
  end
  
end

class InvokeRubyCommand < Command
  
  include InvokeCommands
  
  def do_execute! *args
    # might have more logic in the future
    execute_invoke! 'ruby', *args
  end
  
end

class ReposCommand < Command
  
  acts_as_short
  
  def do_execute_stage_definitions! name, tags, description
    tags = parse_tags(tags)
    @repos = @executor.define_repository(name) { Repository.new(@executor.project_dir, name, tags, description) }
    execute_subcommands!
    if override = @executor.override_for(@repos)
      @executor.redefine_repository! name, LocalPseudoRepository.new(override.local_dir, @repos.name)
    else
      @executor.configure_repository! name
    end
  end
  
  def do_git! name, tags, url
    tags = parse_tags(tags)
    @repos.add_location GitLocation.new(name, tags, url)
  end

  def defined_names
    name = @raw_args[0]
    raise UnresolvedNameError if name =~ %r!/!
    [name]
  end
  
end

class StoreCommand < Command
  
  acts_as_short
  
  def do_execute_stage_definitions! name, tags, description
    tags = parse_tags(tags)
    @store = @executor.define_store(name) { RemoteStore.new(@executor.local_store, name, tags, description) }
    execute_subcommands!
  end
  
  def do_scp! *args
    args[0] = parse_tags(args[0])
    @store.add_location! ScpLocation.new(*args)
  end
  
  def do_http! *args
    args[0] = parse_tags(args[0])
    @store.add_location! HttpLocation.new(*args)
  end
  
  def do_s3! *args
    args[0] = parse_tags(args[0])
    @store.add_location! AmazonS3Location.new(*args)
  end

  def defined_names
    name = @raw_args[0]
    raise UnresolvedNameError if name =~ %r!/!
    [name]
  end
  
end

class VersionCommand < Command
  
  acts_as_short
  
  def do_execute_stage_definitions! version_name, repos_name, *args
    version_name = @executor.resolve_alias(version_name)
    repository = @executor.find_repository(repos_name)
    @executor.define_item! repository.create_item(version_name, *args)
  end

  def defined_names
    name = @raw_args[0]
    raise UnresolvedNameError if name =~ %r!/!
    [name, @executor.resolve_alias(name)].uniq
  end
  
end

module ItemDefinitionCommands
  
  def included(klass)
    klass.send(:acts_as_short)
  end
  
  def execute_new_item! kind, alias_name, tags, name, description
    name = @executor.resolve_alias(name)
    description = name if description == '' || description == '-'
    name = @executor.expand_per_build_name(name)
    description = @executor.expand_per_build_descr(description)
    @executor.define_alias alias_name, name unless alias_name =~ /^-?$/
    tags = parse_tags(tags)
    @executor.define_item! @executor.local_store.new_item(kind, name, tags, description)
  end

  def execute_existing_item! kind, alias_name, tags, name, store_and_path
    name = @executor.resolve_alias(name)
    @executor.define_alias alias_name, name unless alias_name =~ /^-?$/
    tags = parse_tags(tags)
    description = name if description == '' || description == '-'
    
    store_name, path = store_and_path.split('/')
    store = @executor.find_store(store_name)
    @executor.define_item! store.existing_item(kind, name, tags, '')
  end

  def defined_names
    alias_name, name = @raw_args[0], @raw_args[2]
    raise UnresolvedNameError if alias_name =~ %r!/!
    raise UnresolvedNameError if name =~ %r!/!
    [alias_name, @executor.resolve_alias(name)].uniq
  end
  
end

class NewFileCommand < Command
  
  include ItemDefinitionCommands
  
  def do_execute_stage_definitions! alias_name, tags, name, description
    execute_new_item! :file, alias_name, tags, name, description
  end
  
end

class NewDirCommand < Command
  
  include ItemDefinitionCommands
  
  def do_execute_stage_definitions! alias_name, tags, name, description
    execute_new_item! :directory, alias_name, tags, name, description
  end
  
end

class FileCommand < Command
  
  include ItemDefinitionCommands
  
  def do_execute_stage_definitions! alias_name, tags, name, store_and_path
    execute_existing_item! :file, alias_name, tags, name, store_and_path
  end
  
end

class DirCommand < Command
  
  include ItemDefinitionCommands
  
  def do_execute_stage_definitions! alias_name, tags, name, store_and_path
    execute_existing_item! :directory, alias_name, tags, name, description
  end
  
end

class AliasCommand < Command
  
  acts_as_short
  
  def do_execute_stage_definitions! name, item_name
    @executor.define_alias name, item_name
  end

  def defined_names
    name = @raw_args[0]
    raise UnresolvedNameError if name =~ %r!/!
    [name]
  end
  
end

class PutCommand < Command
  
  def determine_inputs_and_outputs! executor, feedback
    @raw_args[1..-1].each do |name|
      name = executor.resolve_alias(name)
      add_input! name if item = executor.items[name]
    end
  end
  
  def do_execute! store_name, *item_names
    store = @executor.find_store(store_name)
    item_names.each do |item_name|
      item_name = @executor.resolve_alias(item_name)
      item = @executor.find_item(item_name)
      @feedback.info "PUT of #{item.name} into #{store.name}..."
      store.put item, @feedback
    end
  end
  
end

class SyncCommand < Command
  
  def determine_inputs_and_outputs! executor, feedback
    determine_inputs_and_outputs_for @raw_args[0], executor, 2
    determine_inputs_and_outputs_for @raw_args[1], executor, 4
  end
  
  def do_execute! first, second
    @mappings = []
    execute_subcommands!
    YourSway::Sync.synchronize parse_sync_party(first), parse_sync_party(second), @mappings
  end
  
  def do_map! first_prefix, first_actions, second_prefix, second_actions
    @mappings << YourSway::Sync::SyncMapping.new(first_prefix, parse_sync_actions(first_actions),
      second_prefix, parse_sync_actions(second_actions))
  end
  
private

  def parse_sync_actions actions
    case actions
    when 'readonly' then return []
    when 'mirror'   then return [:add, :remove, :replace]
    else
      return actions.split(',').collect do |action|
        case action
        when 'add', 'append', 'remove', 'replace', 'update' then :"#{action}"
        else raise BuildScriptError, "Invalid action '#{action}' in SYNC command"
        end
      end
    end
  end
  
  def determine_inputs_and_outputs_for party_name, executor, index
    party_name = executor.resolve_alias(party_name)
    puts "#{self} - determine_inputs_and_outputs_for(#{party_name}, executor, #{index})"
    if item = executor.items[party_name]
      add_input!  party_name
      add_output! party_name  if @data_lines.any? { |line| line[0] == 'MAP' && line[index] != 'readonly' }
    end
  end
  
  def parse_sync_party party_name
    party_name = @executor.resolve_alias(party_name)
    if item = @executor.items[party_name]
       [item.create_sync_party(@feedback)].each { |party| return party unless party.nil? }
    end
    if store = @executor.stores[party_name]
      [store.create_sync_party(@feedback)].each { |party| return party unless party.nil? }
    end
    return YourSway::Sync::LocalParty.new(party_name, @feedback) if File.directory? party_name
    expanded_path = File.expand_path(party_name)
    return YourSway::Sync::LocalParty.new(expanded_path, @feedback) if File.directory? expanded_path
    raise BuildScriptError, "SYNC: unrecognized party spec '#{party_name}'"
  end

end

class ZipCommand < Command
  
  def do_execute! dst_file
    @specs = []
    execute_subcommands!

    tmp_dir = "#{dst_file}.ztmp"
    FileUtils.mkdir_p tmp_dir
    @specs.each do |dst_suffix, src|
      dst_suffix = dst_suffix[1..-1] if dst_suffix[0..0] == '/'
      dst = "#{tmp_dir}/#{dst_suffix}"
      raise "#{src} does not exist" unless File.exists? src
      raise "#{src} is a file, but #{dst_suffix} is already a directory when zipping #{src_file}" if File.file?(src) && File.directory?(dst)
      cp_merge src, dst
    end

    FileUtils.cd tmp_dir do
      case dst_file
      when /\.zip$/, /\.jar$/
        invoke! 'zip', '-r', dst_file, *list_entries(tmp_dir)
      when /\.tar$/
        invoke! 'tar', 'cf', dst_file, *list_entries(tmp_dir)
      when /\.tar\.bz2$/
        invoke! 'tar', 'cjf', dst_file, *list_entries(tmp_dir)
      when /\.tar\.gz$/, /\.tgz$/
        invoke! 'tar', 'czf', dst_file, *list_entries(tmp_dir)
      else
        raise "Don't know how to compress into #{dst_file}"
      end
    end
    FileUtils.rm_rf(tmp_dir)
  end
  
  def do_into! dst, src
    @specs << [dst, src]
  end
  
end

class UnzipCommand < Command
  
  def do_execute! src_file, dst_dir
    @specs = []
    execute_subcommands!

    tmp_dir = "#{dst_dir}/.xtmp"
    FileUtils.mkdir_p tmp_dir
    FileUtils.cd tmp_dir do
      case src_file
      when /\.zip$/, /\.jar$/
        invoke! 'unzip', '-x', src_file
      when /\.tar$/
        invoke! 'tar', 'xf', src_file
      when /\.tar\.bz2$/
        invoke! 'tar', 'xjf', src_file
      when /\.tar\.gz$/, /\.tgz$/
        invoke! 'tar', 'xzf', src_file
      else
        raise "Don't know how to extract #{src_file}"
      end
    end
    @specs.each do |dst_suffix, src_suffix|
      src_suffix = src_suffix[1..-1] if src_suffix[0..0] == '/'
      dst_suffix = dst_suffix[1..-1] if dst_suffix[0..0] == '/'
      src = "#{tmp_dir}/#{src_suffix}"
      dst = "#{dst_dir}/#{dst_suffix}"
      raise "#{src_suffix} does not exist in #{src_file}" unless File.exists? src
      raise "#{src_suffix} is a file, but #{dst_suffix} is already a directory when unzipping #{src_file}" if File.file?(src) && File.directory?(dst)
      mv_merge src, dst
    end
    FileUtils.rm_rf(tmp_dir)
  end
  
  def do_into! dst, src
    @specs << [dst, src]
  end
  
end

class CopyToCommand < Command
  
  def do_execute! destination_dir
    @destination_dir = destination_dir
    execute_subcommands!
 end
  
  def do_into! dest_suffix, src
    dest = File.join(@destination_dir, dest_suffix)
    raise "#{src} does not exist (in COPYTO)" unless File.exists? src
    raise "#{src} is a file, but #{dest} is already a directory (in COPYTO)" if File.file?(src) && File.directory?(dest)
    cp_merge src, dest
  end
  
  def do_symlink! dest_suffix, src
    dest = File.join(@destination_dir, dest_suffix)
    raise "#{src} does not exist (in COPYTO)" unless File.exists? src
    raise "#{dest} already exists (in COPYTO)" if File.exists? dest
    FileUtils.mkdir_p File.dirname(dest)
    FileUtils.ln_s src, dest
  end

end

class FixPlistCommand < Command
  
  def do_execute! file
    lines = File.read(file).split("\n")
    execute_subcommands! lines
    File.open(file, 'w') { |f| f.write(lines.join("\n")) }
  end
  
  def do_fix! lines, header, value
    lines.each { |$_| gsub!(/<string>([^<]+)<\/string>/) { "<string>#{value}</string>" } if ($_ =~ /<key>#{header}<\/key>/) ... (/<key>/) }
  end
  
end

class SubstVarsCommand < Command
  
  def do_execute! file, delimiters='[]'
    @additional_variables = {}
    execute_subcommands!
    data = File.read(file)
    data = subst_variables(data, delimiters[0..delimiters.length/2-1], delimiters[delimiters.length/2..-1])
    File.open(file, 'w') { |f| f.write data}
  end
  
  def do_set! key, value
    @additional_variables[key] = value
  end
  
private
  
  def subst_variables text, beg, fin
    beg_escaped = Regexp.escape(beg)
    fin_escaped = Regexp.escape(fin)
    pattern = /#{beg_escaped}([^#{beg_escaped}#{fin_escaped}]+)#{fin_escaped}/
    collect_refs_in(text, pattern).uniq.each { |ref| @additional_variables[ref.name] ||= @executor.resolve_variable(ref.name) }
    subst_refs_in(text, @additional_variables, pattern)
  end
  
end

class NsisFileListCommand < Command
  
  def do_execute! source_dir, inst_file, uninst_file
    files = list_entries_recursively(source_dir)
    common_prefix = File.join(source_dir, 'x')[0..-2] # a trick to add a trailing slash
    last_dir = source_dir = common_prefix[0..-2] # without a slash
    File.open(inst_file, 'w') do |instf|
      for file in files.sort
        next unless File.file? file
        dir = File.dirname(file)
        if dir != last_dir
          last_dir = dir
          rel_dir = "$INSTDIR" + ("\\" + dir.drop_prefix_or_fail(common_prefix) rescue "").gsub('/', '\\').gsub('$', '$$')
          instf.puts %Q!SetOutPath "#{rel_dir}"!
        end
        instf.puts %Q!File "#{file}"!
      end
    end 
    File.open(uninst_file, 'w') do |uninstf|
      for file in files
        next unless File.file? file
        rel_file = file.drop_prefix_or_fail(common_prefix).gsub('/', '\\').gsub('$', '$$')
        uninstf.puts %Q!Delete "$INSTDIR\\#{rel_file}"!
      end
      for dir in files
        next unless File.directory? dir
        rel_dir = dir.drop_prefix_or_fail(common_prefix).gsub('/', '\\').gsub('$', '$$')
        uninstf.puts %Q!RmDir "$INSTDIR\\#{rel_dir}"!
      end
    end
  end
  
end

class SleepCommand < Command
  
  def do_execute! delay
    delay = delay.to_f
    while delay > 0
      @feedback.info "Sleeping, #{delay} seconds left..."
      sleep 0.5
      delay -= 0.5
    end
  end
  
end

class NopCommand < Command
  
  def do_execute! 
  end
  
end

class ChooseCommand < Command
  
  def do_execute_stage_definitions! repo_name, reason, location_name
    @executor.set_preferred_location repo_name, reason, location_name
  end
  
end

