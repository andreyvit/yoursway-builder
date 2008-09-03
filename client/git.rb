
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
  
  attr_reader :name, :score, :url
  
  def initialize name, score, url
    @name = name
    @score = score.to_i
    @url = url
  end
  
end

class GitRepository
  
  attr_reader :name
  attr_reader :locations
  
  def initialize project_dir, name
    @project_dir = project_dir
    @name = name
    @locations = []
    @prefetched = false
  end
  
  def add_location location
    @locations << location
  end
  
  def create_item name, *spec
    GitItem.new(self, name, parse_version(*spec))
  end
  
  def fetch_version(item, feedback)
    folder = File.join(@project_dir, @name)
    prefetch_locally folder, feedback
    FileUtils.cd(folder) do
      invoke(feedback, 'git', 'reset', '--hard', item.version.ref_name(@definitive_location.name))
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
    locations = @locations.select { |loc| GitLocation === loc }.sort { |b, a| a.score <=> b.score }
    locations.each do |loc|
      # remove the remote in case the URL has changed
      invoke(feedback, 'git', 'config', '--remove-section', "remote.#{loc.name}") rescue nil
      invoke(feedback, 'git', 'remote', 'add', loc.name, loc.url) rescue nil
      invoke(feedback, 'git', 'fetch', loc.name)
    end
    @definitive_location = locations.last
  end
  
  def parse_version spec
    case spec
    when %r!^heads/! then GitBranchVersion.new($')
    when %r!^tags/!  then GitTagVersion.new($')
    else raise "Invalid Git version spec: #{spec}."
    end
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
  
end
