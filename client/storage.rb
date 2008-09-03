
class Item
  
  def in_local_store?
    false
  end

  # name
  # fetch_locally
  
end

class RepositoryItem < Item

end

module LocalItem
  
  def obliterate_completely!
    path = @store.path_of(self)
    FileUtils.rm_rf path
  end
  
  def bring_parent_to_life!
    path = @store.path_of(self)
    FileUtils.mkdir_p File.dirname(path)
  end
  
  def bring_me_to_life!
    path = @store.path_of(self)
    initialize_new_location path
  end
  
  def in_local_store?
    true
  end
  
  def is_fetching_very_fast?
    true
  end
  
end

class StoreItem < Item
  
  attr_reader :name, :tags, :description
  
  def initialize store, name, tags, description
    @store = store
    @name = name
    @tags = tags
    @description = description
    @used = false
  end
  
  def fetch_locally feedback
    @used = true
    return @store.fetch_locally(self, feedback)
  end
  
  def is_fetching_very_fast?
    @store.is_fetching_very_fast?(self)
  end
  
  def used?
    @used
  end
  
  def has_been_put_into store
    @store.item_has_been_put_into self, store
  end
  
  def file?
    :file == kind
  end
  
  def directory?
    :directory == kind
  end
  
end

class StoreDir < StoreItem
  
  def initialize_new_location path
    FileUtils.mkdir_p path
  end
  
  def kind
    :directory
  end
  
end

class StoreFile < StoreItem
  
  def initialize_new_location path
    FileUtils.mkdir_p File.dirname(path)
  end
  
  def kind
    :file
  end
  
end

class Location
  
  attr_reader :tags
  
  def initialize tags
    @tags = tags
  end
  
  def public?
    @tags.include? 'public'
  end
  
  def url?
    :url == kind
  end
  
  def put item, feedback
    raise "#{self.class.name} does not support puts, so cannot put #{item.name}"
  end
  
  def is_fetching_very_fast? item
    false
  end
    
end

class LocalFileSystemLocation < Location
  
  attr_reader :path
  
  def initialize tags, builder_name, path
    super(tags)
    @builder_name = builder_name
    @path = path
  end
  
  def path_of item
    File.join(@path, item.name)
  end
    
  def kind
    :filesystem
  end
  
  def describe_location_of(item)
    "#{@builder_name}:#{File.join(@path, item.name)}"
  end
  
  def is_fetching_very_fast? item
    true
  end
  
end

class HttpLocation < Location
  
  attr_reader :url
  
  def initialize tags, url
    super(tags)
    @url = url
  end
  
  def kind
    :url
  end
  
  def describe_location_of(item)
    uri = URI::parse(@url)
    uri.path = "#{uri.path}/#{item.name}"
    return uri.to_s
  end
  
  def fetch_locally_into item, local_path, feedback
    raise "Fetching directories via HTTP is not supported" if item.directory?

    uri = URI::parse(@url)
    uri.path = "#{uri.path}/#{item.name}"
    feedback.action "Downloading from #{uri}..."

    FileUtils.mkdir_p(File.dirname(local_path))
    begin
      with_automatic_retries(5) do
        File.open(local_path, 'wb') do |file|
          http = Net::HTTP.new(uri.host, uri.port.to_i)
          http.use_ssl = (uri.scheme == 'https')
          http.start do
            http.request_get(uri.request_uri) do |response|
              raise HttpError.new(response.code) unless Net::HTTPOK === response
              len = response.content_length
              done = 0
              begin
                feedback.command_output "#{item.name}..."
                response.read_body do |chunk|
                  file.write(chunk)
                  done += chunk.length
                  feedback.command_output "\r#{item.name}... #{done.format_size_of_size(len, 1)}     "
                end
              ensure
                feedback.command_output "\n"
              end
            end
          end
        end
      end
    rescue Exception
      File.unlink(local_path)
      raise
    end
  end
  
end

class ScpLocation < Location
  
  def initialize tags, path
    super(tags)
    @path = path
  end

  def kind
    :filesystem
  end

  def describe_location_of(item)
    "#{@path}/#{item.name}"
  end
  
  def put item, feedback
    local_path = item.fetch_locally(feedback)
    feedback.action "Uploading #{item.name} into #{@path}/ via SCP..."
    invoke feedback, 'scp', '-r', local_path, "#{@path}/#{item.name}"
  end
  
  def fetch_locally_into item, local_path, feedback
    FileUtils.mkdir_p(File.dirname(local_path))
    feedback.action "Downloading #{item.name} from #{@path}/ via SCP..."
    if item.file?
      invoke feedback, 'scp', "#{@path}/#{item.name}", local_path
    else
      FileUtils.mkdir_p local_path
      invoke feedback, 'scp', '-r', "#{@path}/#{item.name}", local_path
    end
  end
  
end

class AmazonS3Location < Location
  
  # accesskey!secretkey!bucket:path
  def initialize tags, path
    super(tags)
    raise "invalid S3 path format '#{path}', should be accesskey!secretkey!bucket:key_prefix" unless path =~ /^([^!]+)!([^!]+)!([^:]+):/
    @access_key = $1
    @secret_access_key = $2
    @bucket = $3
    @key_prefix = $'
  end

  def kind
    :s3
  end

  def describe_location_of(item)
    "#{@bucket}:#{@key_prefix}#{item.name}"
  end
  
  def put item, feedback
    raise "cannot upload a directory to S3 (not supported yet, and not needed)" if item.directory?
    local_path = item.fetch_locally(feedback)
    s3 = AmazonS3.new(@access_key, @secret_access_key)
    feedback.action "Uploading #{item.name} into #{@bucket}:#{@key_prefix} on Amazon S3..."
    s3.put_file @bucket, "#{@key_prefix}#{item.name}", local_path
  end
  
  def fetch_locally_into item, local_path, feedback
    raise "GETs from Amazon S3 are not supported (please set up an HTTP location for GETs)"
  end
  
end

class Store
  
  KINDS = { :file => StoreFile, :directory => StoreDir }
  
  attr_reader :name, :locations, :description, :tags
  
  def initialize name, tags, description
    @name = name
    @tags = tags
    @description = description
    @locations = []
  end
  
  def add_location! location
    @locations << location
  end
  
  def item_has_been_put_into item, store
  end
  
  def public?
    @tags.include? 'public'
  end
  
end

class LocalStore < Store
  
  def initialize builder_name, tags, path
    super(builder_name, tags, '')
    @local_location = LocalFileSystemLocation.new(['public'], builder_name, path)
    @locations << @local_location
    @item_stores = {}
  end
  
  def fetch_locally item, feedback
    return path_of(item)
  end
  
  def is_fetching_very_fast? item
    true
  end
  
  def path_of item
    @local_location.path_of(item)
  end
  
  def all_items
    @item_stores.keys
  end
  
  def stores_for item
    @item_stores[item] || []
  end
  
  def new_item kind, name, tags, description
     item = KINDS[kind].new(self, name, tags, description)
     item.extend LocalItem
     item.initialize_new_location path_of(item)
     item.has_been_put_into self
     return item
  end
  
  def item_has_been_put_into item, store
    (@item_stores[item] ||= []) << store
  end
  
  def fetch_remote_item item, remote_store, feedback
    path = path_of(item)
    return path if File.exists?(path)
    remote_store.fetch_locally_into(item, path, feedback)
    return path
  end
  
  def has_remote_item? item
    File.exists?(path_of(item))
  end
  
  def local?
    true
  end
  
end

class RemoteStore < Store
  
  def initialize local_store, name, tags, description
    super(name, tags, description)
    @local_store = local_store
  end
  
  def item_has_been_put_into item, store
  end
  
  def existing_item kind, name, tags, description
     item = KINDS[kind].new(self, name, tags, description)
     return item
  end
  
  def put item, feedback
    @locations.first.put item, feedback
    item.has_been_put_into self
  end
  
  def fetch_locally item, feedback
    return @local_store.fetch_remote_item(item, self, feedback)
  end
  
  def is_fetching_very_fast? item
    @locations.last.is_fetching_very_fast?(item) or @local_store.has_remote_item?(item)
  end
  
  def fetch_locally_into item, local_path, feedback
    @locations.last.fetch_locally_into item, local_path, feedback
  end
  
  def local?
    false
  end
  
end
