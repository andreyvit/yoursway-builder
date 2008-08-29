
require 'fileutils'

require File.join(File.dirname(__FILE__), 'commons.rb')

class GitItem < RepositoryItem
  
  attr_reader :version
  
  def initialize repository, name, version
    @repository = repository
    @name = name
    @version = version
    @path = nil
  end
  
  def fetch_locally
    return @repository.fetch_version(self)
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
  
  def prefetch_locally(folder)
    return if @prefetched
    @prefetched = true
    
    FileUtils.mkdir_p folder
    Dir.chdir folder
    invoke('git', 'init') rescue nil
    locations = @locations.select { |loc| GitLocation === loc }.sort { |b, a| a.score <=> b.score }
    locations.each do |loc|
      invoke('git', 'remote', 'add', loc.name, loc.url) rescue nil
      invoke('git', 'fetch', loc.name)
    end
    @definitive_location = locations.last
  end
  
  def fetch_version(item)
    folder = File.join(@project_dir, @name)
    prefetch_locally folder
    FileUtils.cd(folder) do
      invoke('git', 'reset', '--hard', item.version.ref_name(@definitive_location.name))
    end
    return folder
  end

private
  
  def parse_version spec
    case spec
    when %r!^heads/! then GitBranchVersion.new($')
    when %r!^tags/!  then GitTagVersion.new($')
    else raise "Invalid Git version spec: #{spec}."
    end
  end

end
