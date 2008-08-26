
class Item

  # name
  # fetch_locally storage_dir
  
end

class RepositoryItem < Item
end

class StoreItem < Item
  
  attr_reader :name, :tags, :description
  
  def initialize store, name, tags, description
    @store = store
    @name = name
    @tags = tags
    @description = description
  end
  
  def fetch_locally local_store
    return @store.fetch_locally(local_store, self)
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
  
  def put item
    raise "#{self.class.name} does not support puts, so cannot put #{item.name}"
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
    "#{url}/#{item.name}"
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
  
  def put item
    local_path = item.fetch_locally(nil)
    invoke 'scp', '-r', local_path, "#{@path}/#{item.name}"
  end
  
end

class AmazonS3Location < Location
  
  # accesskey!secretkey!bucket:path
  def initialize tags, path
    super(tags)
    raise "invalid S3 path format '#{path}', should be accesskey!secretkey!bucket:path" unless path =~ /^([^!]+)!([^!]+)!([^:]+):/
    @access_key = $1
    @secret_access_key = $2
    @bucket = $3
    @path = $'
    @path = "#{@path}/" if @path.length > 0 && @path[-1..-1] != '/'
  end

  def kind
    :s3
  end

  def describe_location_of(item)
    "#{@bucket}:#{@path}/#{item.name}"
  end
  
  def put item
    raise "cannot upload a directory to S3 (not supported yet, and not needed)" if item.directory?
    local_path = item.fetch_locally(nil)
    s3 = AmazonS3.new(@access_key, @secret_access_key)
    s3.put_file @bucket, "#{@path}#{item.name}", local_path
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
  
  def fetch_locally local_store, item
    return path_of(item)
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
     item.initialize_new_location path_of(item)
     item.has_been_put_into self
     return item
  end
  
  def item_has_been_put_into item, store
    (@item_stores[item] ||= []) << store
  end
  
end

class RemoteStore < Store
  
  def initialize name, tags, description
    super(name, tags, description)
  end
  
  def put item
    @locations.first.put item
    item.has_been_put_into self
  end
  
end
