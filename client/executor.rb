
['commons.rb', 'git.rb'].each { |file_name| require File.join(File.dirname(__FILE__), file_name) }

class Executor
  
  def initialize
    @variables = {}
    @repositories = {}
    @items = {}
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
    else
      log "Unknown command #{command}(#{args.join(', ')})"
    end
  end
  
private
  
  def subst value
    return value.gsub(/\[([^\]]+)\]/) { |var|
      @variables[$1] or get_item($1) or raise ExecutionError.new("Undefined variable or item [#{$1}]")
    }
  end
  
  def get_item name
    item = @items[name] or return nil
    item.fetch_locally(@project_dir)
  end
  
  def do_project name
    @variables['project'] = name
    @project_dir = File.join(@storage_dir, name)
    FileUtils.mkdir_p(@project_dir)
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
    raise "Duplicate version #{name}" unless @items[version_name].nil?
    repository = @repositories[repos_name]
    raise "Unknown repository #{repos_name}" if repository.nil?
    @items[version_name] = repository.create_item(version_name, *args)
  end
  
end
