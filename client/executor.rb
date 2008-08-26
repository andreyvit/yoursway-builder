
['commons.rb', 'git.rb'].each { |file_name| require File.join(File.dirname(__FILE__), file_name) }

class Executor
  
  def initialize
    @variables = {}
    @repositories = {}
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
      do_invoke *args
    when 'GITREPOS'
      do_gitrepos data_lines, *args
    when 'VERSION'
      do_version *args
    when 'NEWDIR'
      do_new_item :directory, *args
    when 'NEWFILE'
      do_new_item :file, *args
    when 'ALIAS'
      do_alias *args
    else
      log "Unknown command #{command}(#{args.join(', ')})"
    end
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
    @project_dir = File.join(@storage_dir, name)
    FileUtils.mkdir_p(@project_dir)
    
    @local_store = LocalStore.new(File.join(@project_dir, 'localitems'))
  end
  
  def do_say text
    log "Saying #{text}"
    invoke('say', text)
  end
  
  def do_set name, value
    @variables[name] = value
  end
  
  def do_invoke app, *args
    args = [''] if args.empty? # or else shell will be invoked
    log "Invoking #{app} with arguments #{args.join(', ')}"
    system(app, *args)
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
  
  def resolve_alias name
    @aliases[name] || name
  end
  
end
