
class Item

  # name
  # fetch_locally storage_dir
  
end

class RepositoryItem < Item
end

class StoreItem < Item
  
  attr_reader :name, :tags, :description
  attr_reader :path
  
  def initialize store, name, tags, description
    @store = store
    @name = name
    @tags = tags
    @description = description
    @path = File.join(store.path, name)
  end
  
  def fetch_locally storage_dir
    @store.fetch_locally self
    return @path
  end
  
end

class StoreDir < StoreItem
  
  def initialize *args
    super *args
    FileUtils.mkdir_p @path
  end
  
end

class StoreFile < StoreItem
  
  def initialize *args
    super *args
    FileUtils.mkdir_p File.dirname(@path)
  end
  
end

class LocalStore
  
  KINDS = { :file => StoreFile, :directory => StoreDir }
  
  attr_reader :path
  
  def initialize path
    @path = path
  end
  
  def new_item kind, name, tags, description
     KINDS[kind].new(self, name, tags, description)
  end
  
  def fetch_locally item
    # already local
  end
  
end
