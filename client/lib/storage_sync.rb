
class RepositoryItem
  
  def create_sync_party feedback
    raise "Repository items are not supported by sync"
  end
  
end

class StoreItem
  
  def create_sync_party feedback
    @store.create_sync_party feedback, self
  end

end

class LocalStore

  def create_sync_party feedback, item=nil
    @local_location.create_sync_party feedback, item
  end
  
end

class RemoteStore

  def create_sync_party feedback, item=nil
    @locations.each do |location|
      party = location.create_sync_party feedback, item
      return party unless party.nil?
    end
  end
  
end

class Location
  
  def create_sync_party feedback, item=nil
    nil
  end
  
end

class LocalFileSystemLocation
  
  def create_sync_party feedback, item=nil
    YourSway::Sync::LocalParty.new(if item.nil? then @path else path_of(item) end, feedback)
  end
  
end

class AmazonS3Location
  
  def create_sync_party feedback, item=nil
    sync_key_prefix = if item.nil? then @key_prefix else "#{@key_prefix}#{item.name}" end
    YourSway::Sync::S3Party.new(AmazonS3.new(@access_key, @secret_access_key), @bucket, sync_key_prefix, feedback)
  end
  
end
