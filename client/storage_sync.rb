
class RepositoryItem
  
  def create_sync_party
    raise "Repository items are not supported by sync"
  end
  
end

class StoreItem
  
  def create_sync_party
    @store.create_sync_party self
  end

end

class LocalStore

  def create_sync_party item=nil
    @local_location.create_sync_party item
  end
  
end

class RemoteStore

  def create_sync_party item=nil
    @locations.each do |location|
      party = location.create_sync_party item
      return party unless party.nil?
    end
  end
  
end

class Location
  
  def create_sync_party item=nil
    nil
  end
  
end

class LocalFileSystemLocation
  
  def create_sync_party item=nil
    YourSway::Sync::LocalParty.new(if item.nil? then @path else path_of(item) end)
  end
  
end

class AmazonS3Location
  
  def create_sync_party item=nil
    sync_key_prefix = if item.nil? then @key_prefix else "#{@key_prefix}#{item.name}" end
    YourSway::Sync::S3Party.new(AmazonS3.new(@access_key, @secret_access_key), @bucket, sync_key_prefix)
  end
  
end
