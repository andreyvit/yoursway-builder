
require 'fileutils'

require File.join(File.dirname(__FILE__), 'commons.rb')

class GitItem < RepositoryItem
  
  attr_reader :version, :name
  
  def initialize repository, name, version
    @repository = repository
    @name = name
    @version = version
    @path = nil
    @fetched_path = nil
  end
  
  def fetch_locally feedback
    @fetched_path ||= @repository.fetch_version(self, feedback)
  end
  
  def is_fetching_very_fast?
    !@fetched_path.nil?
  end

end

class GitBranchVersion
  
  def initialize branch
    @branch = branch
  end
  
  def ref_name(remote_name)
    "refs/remotes/#{remote_name}/#{@branch}"
  end
  
end

class GitTagVersion
  
  def initialize tag
    @tag = tag
  end
  
  def ref_name(remote_name)
    "refs/tags/#{@tag}"
  end
  
end

class GitLocation
  
  attr_reader :name, :tags, :url
  
  def initialize name, tags, url
    @name = name
    @tags = tags
    @url = url
    @prefetched = false
  end
  
  def initiate_repos_info! project_dir, repos_name
    @project_dir = project_dir
    @repos_name = repos_name
  end
  
  def create_item name, *spec
    GitItem.new(self, name, parse_version(*spec))
  end
  
  def fetch_version(item, feedback)
    folder = File.join(@project_dir, @repos_name)
    prefetch_locally folder, feedback
    FileUtils.cd(folder) do
      invoke(feedback, 'git', 'reset', '--hard', item.version.ref_name(@name))
    end
    return folder
  end

private

  def prefetch_locally(folder, feedback)
    return if @prefetched
    @prefetched = true
    
    FileUtils.mkdir_p folder
    Dir.chdir folder
    invoke(feedback, 'git', 'init') rescue nil
    
    # TODO: the same, but for mirrors
    # locations = @locations.select { |loc| GitLocation === loc }.sort { |b, a| a.score <=> b.score }
    
      # remove the remote in case the URL has changed
    invoke(feedback, 'git', 'config', '--remove-section', "remote.#{@name}") rescue nil
    invoke(feedback, 'git', 'remote', 'add', @name, @url) rescue nil
    invoke(feedback, 'git', 'fetch', @name)
  end
  
  def parse_version spec
    case spec
    when %r!^heads/! then GitBranchVersion.new($')
    when %r!^tags/!  then GitTagVersion.new($')
    else raise "Invalid Git version spec: #{spec}."
    end
  end
  
end

class Repository
  
  attr_reader :name, :tags, :description
  attr_reader :locations
  
  def initialize project_dir, name, tags, description
    @project_dir = project_dir
    @name = name
    @tags = tags
    @description = description
    @locations = []
    @active_location = nil
  end
  
  def add_location location
    @locations << location
    location.initiate_repos_info! @project_dir, @name
  end
  
  def active_location
    @active_location ||= choose_location
  end
  
  def create_item name, tags, *spec
    active_location.create_item name, tags, *spec
  end
  
  def fetch_version(item, feedback)
    active_location.fetch_version item, feedback
  end
  
  def set_preferred_location! location_name
    raise BuildScriptError, "Too late to choose a location for #{@name}" unless @active_location.nil?
    @active_location = @locations.find { |loc| loc.name == location_name }
    raise "Location #{location_name} does not exist in repository #{@name}" if @active_location.nil?
  end

private

  def choose_location
    @locations.first
  end

end

class LocalPseudoVersion
end

class LocalPseudoRepository
  
  attr_reader :name
  
  def initialize local_dir, name
    @name = name
    @local_dir = local_dir
  end
  
  def create_item name, *spec
    GitItem.new(self, name, LocalPseudoVersion.new)
  end

  def fetch_version item, feedback
    @local_dir
  end
  
  def set_preferred_location! location_name
  end
  
end
