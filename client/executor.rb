
['commons.rb', 'git.rb', 'amazons3.rb'].each { |file_name| load File.join(File.dirname(__FILE__), file_name) }

def invoke cmd, *args
  args = [''] if args.empty?
  msg = "INVOKE #{cmd}#{args.collect {|a| "\n  ARG #{a}"}.join('')}"
  log msg
  if not system(cmd, *args) 
    basename = File.basename(cmd)
    summary = case $?.exitstatus
        when 127 then "'#{basename}' not found"
        else          "'#{basename}' failed with code #{$?.exitstatus}"
    end
    raise "#{summary}\n#{msg}"
  end
end

class String
  
  def subst_empty default_value
    if self.empty? then default_value else self end
  end
  
end

class Executor
  
  def initialize builder_name
    @builder_name = builder_name # used to make create a local store name
    @variables = {}
    @repositories = {}
    @stores = {}
    @items = {}
    @aliases = {}
    @storage_dir = '/tmp/storage'
  end
  
  def execute command, args, data_lines
    args.collect! { |arg| subst(arg) }
    data_lines.each { |line|
      line.collect! { |arg| subst(arg) }
    }
    
    case command.upcase
    when 'PROJECT'
      do_project *args
    when 'SAY'
      do_say *args
    when 'SET'
      do_set *args
    when 'INVOKE'
      do_invoke data_lines, *args
    when 'INVOKERUBY'
      do_invoke_ruby data_lines, *args
    when 'GITREPOS'
      do_gitrepos data_lines, *args
    when 'STORE'
      do_store data_lines, *args
    when 'VERSION'
      do_version *args
    when 'NEWDIR'
      do_new_item :directory, *args
    when 'NEWFILE'
      do_new_item :file, *args
    when 'ALIAS'
      do_alias *args
    when 'PUT'
      do_put *args
    else
      log "Unknown command #{command}(#{args.join(', ')})"
    end
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
  
private
  
  def subst value
    loop do
      result = value.gsub(/\[([^\[\]]+)\]/) { |var|
        @variables[$1] or get_item($1) or raise ExecutionError.new("Undefined variable or item [#{$1}]")
      }
      return result if result == value
      value = result
    end
  end
  
  def get_item name
    name = resolve_alias(name)
    item = @items[name] or return nil
    item.fetch_locally(@project_dir)
  end
  
  def do_project permalink, name
    @variables['project'] = permalink
    @variables['project-name'] = name
    @project_dir = File.join(@storage_dir, permalink)
    FileUtils.mkdir_p(@project_dir)
    
    @local_store = LocalStore.new(@builder_name, [], File.join(@project_dir, 'localitems'))
    @stores[@local_store.name] = @local_store
  end
  
  def do_say text
    log "Saying #{text}"
    invoke('say', text)
  end
  
  def do_set name, value
    @variables[name] = value
  end
  
  def do_invoke data_lines, app, *args
    for name, value in @variables
      ENV[name] = value
    end
    invoke(app, *args)
  end
  
  def do_invoke_ruby data_lines, *args
    # might have more logic in the future
    do_invoke data_lines, 'ruby', *args
  end
  
  def do_gitrepos data_lines, name
    repos = (@repositories[name] ||= GitRepository.new(name))
    data_lines.each do |subcommand, *args|
      case subcommand.upcase
      when 'GIT'
        repos.add_location GitLocation.new(*args)
      end
    end
  end
  
  def do_store data_lines, name, tags, description
    tags = case tags.strip when '-' then [] else tags.strip.split(/\s*,\s*/) end
    store = (@stores[name] ||= RemoteStore.new(name, tags, description))
    data_lines.each do |subcommand, *args|
      args[0] = case args[0].strip when '-' then [] else args[0].strip.split(/\s*,\s*/) end
      case subcommand.upcase
      when 'SCP'
        store.add_location! ScpLocation.new(*args)
      when 'HTTP'
        store.add_location! HttpLocation.new(*args)
      when 'S3'
        store.add_location! AmazonS3Location.new(*args)
      end
    end
  end
  
  def do_version version_name, repos_name, *args
    version_name = resolve_alias(version_name)
    raise "Duplicate version #{name}" unless @items[version_name].nil?
    repository = @repositories[repos_name]
    raise "Unknown repository #{repos_name}" if repository.nil?
    @items[version_name] = repository.create_item(version_name, *args)
  end
  
  def do_new_item kind, name, tags, description
    name = resolve_alias(name)
    tags = case tags.strip when '-' then [] else tags.strip.split(/\s*,\s*/) end
    item = @local_store.new_item(kind, name, tags, description)
    puts "new item defined: [#{item.name}]"
    @items[item.name] = item
  end
  
  def do_alias name, item_name
    @aliases[name] = resolve_alias(item_name)
  end
  
  def do_put store_name, *item_names
    store = @stores[store_name] or raise "PUT references unknown store '#{store_name}'"
    item_names.each do |item_name|
      item_name = resolve_alias(item_name)
      item = @items[item_name] or raise "PUT references unknown item #{item_name}"
      log "PUT of #{item.name} into #{store.name}..."
      store.put item
    end
  end
  
  def resolve_alias name
    @aliases[name] || name
  end
  
end
