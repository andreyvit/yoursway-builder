
['commons', 'ys_s3', 'storage', 'git', 'sync', 'storage_sync'].each { |file_name| require file_name }

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

class Executor
  
  def initialize builder_name
    @builder_name = builder_name # used to make create a local store name
    @variables = {}
    @repositories = {}
    @stores = {}
    @items = {}
    @aliases = {}
    if File.directory? "/tmp" and not is_windows?
      @storage_dir = "/tmp/ysbuilder-#{builder_name}" 
    else
      @storage_dir = File.join(File.tmpdir, "ysbuilder-#{builder_name}")
    end
    load_alternates_file
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
    when 'DIR'
      do_existing_item :directory, *args
    when 'FILE'
      do_existing_item :file, *args
    when 'ALIAS'
      do_alias *args
    when 'PUT'
      do_put *args
    when 'SYNC'
      do_sync data_lines, *args
    when 'ZIP'
      do_zip data_lines, *args
    when 'UNZIP'
      do_unzip data_lines, *args
    when 'COPYTO'
      do_copyto data_lines, *args
    when 'FIXPLIST'
      do_fix_plist data_lines, *args
    when 'SUBSTVARS'
      do_subst_vars data_lines, *args
    when 'NSIS-FILE-LIST'
      do_nsis_file_list *args
    when 'SLEEP'
      do_sleep *args
    else
      raise BuildScriptError, "Unknown command #{command}(#{args.join(', ')})"
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
  
  def subst value, additional_variables = {}
    loop do
      result = value.gsub(/\[([^\[\]<]+)(?:<([^>]*)>)?\]/) { |var|
        tags = parse_tags($2)
        additional_variables[$1] or @variables[$1] or get_item($1, tags) or raise ExecutionError.new("Undefined variable or item [#{$1}]")
      }
      return result if result == value
      value = result
    end
  end
  
  def get_item name, tags
    name = resolve_alias(name)
    item = @items[name] or return nil
    if item.in_local_store? && !item.used?
      item.bring_parent_to_life!
      item.obliterate_completely! unless tags.include?('keep')
      item.bring_me_to_life! if tags.include?('mkdir')
    end
    item.fetch_locally
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
    data_lines.each do |subcommand, *subargs|
      case subcommand.upcase
      when 'ARG', 'ARGS' then args.push(*subargs)
      end
    end
    invoke(app, *args)
  end
  
  def do_invoke_ruby data_lines, *args
    # might have more logic in the future
    do_invoke data_lines, 'ruby', *args
  end
  
  def do_gitrepos data_lines, name
    repos = (@repositories[name] ||= GitRepository.new(@project_dir, name))
    data_lines.each do |subcommand, *args|
      case subcommand.upcase
      when 'GIT'
        repos.add_location GitLocation.new(*args)
      else
        raise BuildScriptError, "Unknown repository location type #{subcommand}"
      end
    end
    if override = @overrides.find { |o| o.matches? repos }
      @repositories[name] = LocalPseudoRepository.new(override.local_dir, repos.name)
    end
  end
  
  def do_store data_lines, name, tags, description
    tags = case tags.strip when '-' then [] else tags.strip.split(/\s*,\s*/) end
    store = (@stores[name] ||= RemoteStore.new(@local_store, name, tags, description))
    data_lines.each do |subcommand, *args|
      args[0] = case args[0].strip when '-' then [] else args[0].strip.split(/\s*,\s*/) end
      case subcommand.upcase
      when 'SCP'
        store.add_location! ScpLocation.new(*args)
      when 'HTTP'
        store.add_location! HttpLocation.new(*args)
      when 'S3'
        store.add_location! AmazonS3Location.new(*args)
      else
        raise BuildScriptError, "Unknown store location type #{subcommand}"
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
  
  def do_new_item kind, alias_name, tags, name, description
    name = resolve_alias(name)
    define_alias alias_name, name unless alias_name =~ /^-?$/
    tags = parse_tags(tags)
    item = @local_store.new_item(kind, name, tags, description)
    puts "new item defined: [#{item.name}]"
    @items[item.name] = item
  end
  
  def do_existing_item kind, alias_name, tags, name, store_and_path
    name = resolve_alias(name)
    define_alias alias_name, name unless alias_name =~ /^-?$/
    tags = case tags.strip when '-' then [] else tags.strip.split(/\s*,\s*/) end
    store_name, path = store_and_path.split('/')
    store = @stores[store_name] or raise BuildScriptError, "Store #{store_name} not found"
    item = store.existing_item(kind, name, tags, '')
    puts "existing item defined: [#{item.name}]"
    @items[item.name] = item
  end
  
  def do_alias name, item_name
    define_alias name, item_name
  end
  
  def define_alias name, item_name
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
  
  def do_unzip data_lines, src_file, dst_dir
    specs = []
    data_lines.each do |subcommand, *args|
      case subcommand.upcase
      when 'INTO' 
        dst, src = *args
        raise BuildScriptError, "INTO syntax error" if dst.nil? or src.nil?
        specs << [dst, src]
      else raise BuildScriptError, "Unknown UNZIP subcommand #{subcommand}"
      end
    end
    
    tmp_dir = "#{dst_dir}/.xtmp"
    FileUtils.mkdir_p tmp_dir
    FileUtils.cd tmp_dir do
      case src_file
      when /\.zip$/
        invoke 'unzip', '-x', src_file
      when /\.tar$/
        invoke 'tar', 'xf', src_file
      when /\.tar\.bz2$/
        invoke 'tar', 'xjf', src_file
      when /\.tar\.gz$/, /\.tgz$/
        invoke 'tar', 'xzf', src_file
      else
        raise "Don't know how to extract #{src_file}"
      end
    end
    specs.each do |dst_suffix, src_suffix|
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
  
  def do_zip data_lines, dst_file
    specs = []
    data_lines.each do |subcommand, *args|
      case subcommand.upcase
      when 'INTO' 
        dst, src = *args
        raise BuildScriptError, "INTO syntax error" if dst.nil? or src.nil?
        specs << [dst, src]
      else raise BuildScriptError, "Unknown ZIP subcommand #{subcommand}"
      end
    end
    
    tmp_dir = "#{dst_file}.ztmp"
    FileUtils.mkdir_p tmp_dir
    specs.each do |dst_suffix, src|
      dst_suffix = dst_suffix[1..-1] if dst_suffix[0..0] == '/'
      dst = "#{tmp_dir}/#{dst_suffix}"
      raise "#{src} does not exist" unless File.exists? src
      raise "#{src} is a file, but #{dst_suffix} is already a directory when zipping #{src_file}" if File.file?(src) && File.directory?(dst)
      cp_merge src, dst
    end
    
    FileUtils.cd tmp_dir do
      case dst_file
      when /\.zip$/
        invoke 'zip', '-r', dst_file, *list_entries(tmp_dir)
      when /\.tar$/
        invoke 'tar', 'cf', dst_file, *list_entries(tmp_dir)
      when /\.tar\.bz2$/
        invoke 'tar', 'cjf', dst_file, *list_entries(tmp_dir)
      when /\.tar\.gz$/, /\.tgz$/
        invoke 'tar', 'czf', dst_file, *list_entries(tmp_dir)
      else
        raise "Don't know how to compress into #{dst_file}"
      end
    end
    FileUtils.rm_rf(tmp_dir)
  end
  
  def do_copyto data_lines, destination_dir
    data_lines.each do |subcommand, *subargs|
      case subcommand
      when 'INTO'
        dest_suffix, src = *subargs
        dest = File.join(destination_dir, dest_suffix)
        raise "#{src} does not exist (in COPYTO)" unless File.exists? src
        raise "#{src} is a file, but #{dest} is already a directory (in COPYTO)" if File.file?(src) && File.directory?(dest)
        cp_merge src, dest
      when 'SYMLINK'
        dest_suffix, src = *subargs
        dest = File.join(destination_dir, dest_suffix)
        raise "#{src} does not exist (in COPYTO)" unless File.exists? src
        raise "#{dest} already exists (in COPYTO)" if File.exists? dest
        FileUtils.mkdir_p File.dirname(dest)
        FileUtils.ln_s src, dest
      else
        raise BuildScriptError, "Unknown COPYTO subcommand: #{subcommand}"
      end
    end
  end
  
  def parse_sync_actions actions
    case actions
    when 'readonly' then return []
    when 'mirror'   then return [:add, :remove, :replace]
    else
      return actions.split(',').collect do |action|
        case action
        when 'add', 'remove', 'replace', 'update' then :"#{action}"
        else raise BuildScriptError, "Invalid action '#{action}' in SYNC command"
        end
      end
    end
  end
  
  def parse_sync_party party_name
    party_name = resolve_alias(party_name)
    if item = @items[party_name]
       [item.create_sync_party].each { |party| return party unless party.nil? }
    end
    if store = @stores[party_name]
      [store.create_sync_party].each { |party| return party unless party.nil? }
    end
    return YourSway::Sync::LocalParty.new(party_name) if File.directory? party_name
    expanded_path = File.expand_path(party_name)
    return YourSway::Sync::LocalParty.new(expanded_path) if File.directory? expanded_path
    raise BuildScriptError, "SYNC: unrecognized party spec '#{party_name}'"
  end
  
  def do_sync data_lines, first, second
    mappings = []
    data_lines.each do |subcommand, *args|
      case subcommand.upcase
      when 'MAP' 
        first_prefix, first_actions, second_prefix, second_actions = *args
        raise BuildScriptError, "MAP subcommand of SYNC command has incorrect syntax" if second_actions.nil?
        
        mappings << YourSway::Sync::SyncMapping.new(first_prefix, parse_sync_actions(first_actions),
          second_prefix, parse_sync_actions(second_actions))
      else raise BuildScriptError, "Unknown ZIP subcommand #{subcommand}"
      end
    end
    
    YourSway::Sync.synchronize parse_sync_party(first), parse_sync_party(second), mappings
  end
  
  def do_fix_plist data_lines, file
    lines = File.read(file).split("\n")
    data_lines.each do |subcommand, header, value|
      case subcommand
      when 'FIX'
        lines.each { |$_| gsub!(/<string>([^<]+)<\/string>/) { "<string>#{value}</string>" } if ($_ =~ /<key>#{header}<\/key>/) ... (/<key>/) }
      else
        raise "Unknown FIXPLIST subcommand: #{subcommand}"
      end
    end
    File.open(file, 'w') { |f| f.write(lines.join("\n")) }
  end
  
  def do_subst_vars data_lines, file
    additional_variables = {}
    data_lines.each do |subcommand, key, value|
      case subcommand
      when 'SET'
        additional_variables[key] = subst(value, additional_variables)
      else
        raise "Unknown SUBSTVARS subcommand: #{subcommand}"
      end
    end
    data = File.read(file)
    data = subst(data, additional_variables)
    File.open(file, 'w') { |f| f.write data}
  end
  
  def do_nsis_file_list source_dir, inst_file, uninst_file
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
  
  def do_sleep delay
    delay = delay.to_i
    while delay > 0
      sleep 1
      delay -= 1
    end
  end
  
  def resolve_alias name
    @aliases[name] || name
  end
  
  def parse_tags tags_str
    tags_str = (tags_str || '').strip
    return case tags_str when '', '-' then [] else tags_str.split(/\s*,\s*/) end
  end
  
end
