require 'generator'
require 'tempfile'

module YourSway
end

module YourSway::Sync
  
##############################################################################################################
  
  class LocalParty
  
    def initialize dir
      @dir = dir
    end
    
    def connect
      yield LocalConnection.new(@dir)
    end
    
  end
  
  class LocalConnection
    
    def initialize dir
      @dir = dir
    end
    
    def list_files
      list_entries_recursively(@dir, '')
    end
    
    def add! rel_path, file
      path = File.join(@dir, rel_path)
      raise "#{rel_path} already exists" if File.exist? path
      write_file! path, file
    end
    
    def remove! file
      path = File.join(@dir, file.rel_path)
      raise "#{rel_path} does not exists" unless File.exist? path
      File.unlink path
    end
    
    def replace! old_file, file
      path = File.join(@dir, old_file.rel_path)
      raise "#{rel_path} does not exists" unless File.exist? path
      write_file! path, file
    end
    
  private
  
    def write_file! path, file
      local_path = file.to_local_file
      File.open(path, 'wb') do |f|
        File.open(local_path, 'rb') do |inf|
          while chunk = inf.read(1024*1024) do
            f.write chunk
          end
        end
      end
    end
    
    def list_entries_recursively(path, parent_rel_path, result = [])
      Dir.open(path) do |dir|
        while entry = dir.read
          next if entry == '.' or entry == '..'
          child = File.join(path, entry)
          rel_path = if parent_rel_path == '' then entry else File.join(parent_rel_path, entry) end
          if File.directory? child
            list_entries_recursively child, rel_path, result
          else
            result << LocalFile.new(rel_path, child)
          end
        end
      end
      return result
    end

  end
  
  class LocalFile
    
    attr_reader :rel_path
    
    def initialize rel_path, full_path
      @rel_path = rel_path
      @full_path = full_path
    end
    
    def read_chunks
      File.open(@full_path, 'rb') do |f|
        while chunk = f.read(1024*1024*2)
          yield chunk
        end
      end
    end
    
    def mtime
      File.mtime @full_path
    end
    
    def to_local_file
      return @full_path
    end
    
  end
  
##############################################################################################################

  class ScpParty
    
    def initialize host, path
    end
    
  end
  
  class ScpConnection
  end
  
  class ScpFile
  end

##############################################################################################################
  
  class S3Party
    
    def initialize(amazon, bucket, key_prefix)
      @amazon = amazon
      @bucket = bucket
      @key_prefix = key_prefix
    end
    
    def connect
      @amazon.connect(@bucket, @key_prefix) do |c|
        yield S3Connection.new(c)
      end
    end
    
    def list_files
      @amazon.connect(@bucket, @key_prefix) do |c|
        return c.list.collect { |f| S3File.new(nil, f, f.key) }
      end
    end
    
  end
  
  class S3Connection
    
    def initialize connection
      @connection = connection
    end
    
    def list_files
      @connection.list.collect { |f| S3File.new(@connection, f, f.key) }
    end
    
    def add! rel_path, file
      local_path = file.to_local_file
      @connection.put_file rel_path, local_path
    end
    
    def replace! old_file, file
      add! old_file.rel_path, file
    end
    
    def remove! file
      @connection.delete file.rel_path
    end
    
  end
  
  class S3File
    
    attr_reader :rel_path
    
    def initialize conn, file, rel_path
      @conn = conn
      @file = file
      @rel_path = rel_path
    end
    
    def mtime; @file.mtime; end
    
    def to_local_file
      tempf = Tempfile.new('amazon')
      @conn.get_into_file @rel_path, tempf.path
      return tempf.path
    end
    
  end

##############################################################################################################
  
  class WorkQueue
    
    def initialize
      @jobs = []
    end
    
    def enqueue &block
      @jobs << block
    end
    
    def run_queue! *args
      @jobs.process_and_remove_each { |job| job.call self, *args }
    end
    
  end
  
  class SyncMapping < YourSway::PathMapping
    
    attr_reader :extra_first, :extra_second, :modified, :modified_first, :modified_second
    attr_reader :first_files, :second_files
    
    def initialize first_path, first_actions, second_path, second_actions
      super(first_path, second_path)
      @extra_first  = :just_enjoy # :add, :remove
      @extra_second = :just_enjoy # :add, :remove
      @modified     = :just_enjoy # :compare, :replace_first, :replace_second
      @modified_first = :just_enjoy # :update
      @modified_second = :just_enjoy # :update
      first_actions.each  { |action| self.send(:"enable_#{action}!", :first, :second) }
      second_actions.each { |action| self.send(:"enable_#{action}!", :second, :first) }
      
      @first_files  = []
      @second_files = []
    end
    
    def enable_add! party, other
      raise "cannot both add to #{party} and remove from #{other}" if instance_variable_get("@extra_#{other}") == :remove
      instance_variable_set("@extra_#{other}", :add)
    end
    
    def enable_remove! party, other
      raise "cannot both remove from #{party} and add to #{other}" if instance_variable_get("@extra_#{party}") == :add
      instance_variable_set("@extra_#{party}", :remove)
    end
    
    def enable_replace! party, other
      raise "cannot replace both #{party} and #{other}" if @modified == :"replace_#{other}"
      raise "cannot both replace #{party} and update first or second" if @modified == :compare
      @modified = :"replace_#{party}"
    end
    
    def enable_update! party, other
      raise "cannot both update #{party} and replace either party" if @modified.to_s.starts_with? "replace"
      @modified = :compare
      instance_variable_set("@modified_#{other}", :update)
    end
    # 
    # def other party
    #   case party
    #   when :first then :second
    #   when :second then :first
    #   end
    # end
    
  end
  
  def self.synchronize(first_party, second_party, mappings)
    queue = WorkQueue.new
    queue.enqueue do |q, fc, _|
      first_listing = fc.list_files.sort { |a,b| a.rel_path <=> b.rel_path }
      q.enqueue do |q, _, sc|
        second_listing = sc.list_files.sort { |a,b| a.rel_path <=> b.rel_path }
        process_listings! q, first_listing, second_listing, mappings
      end
    end
    with_automatic_retries(100) do
      first_party.connect do |first_connection|
        second_party.connect do |second_connection|
          queue.run_queue! first_connection, second_connection
        end
      end
    end
  end
  
  def self.process_listings! q, first_listing, second_listing, mappings
    matcher = YourSway::PathMappingMatcher.new(mappings)
    first_listing.each do |file|
      mapping = matcher.lookup_first(file.rel_path)
      mapping.first_files << file unless mapping.nil?
    end
    second_listing.each do |file|
      mapping = matcher.lookup_second(file.rel_path)
      mapping.second_files << file unless mapping.nil?
    end
    
    mappings.each do |mapping|
      diff = YourSway::SequenceDiffer.new
      diff.on_first do |file|
        case mapping.extra_first
        when :just_enjoy
        when :add    then q.enqueue { |_, _, sc| sc.add! mapping.first_to_second(file.rel_path), file }
        when :remove then q.enqueue { |_, fc, _| fc.remove! file }
        else raise "unreachable"
        end
      end
      diff.on_second do |file|
        case mapping.extra_second
        when :just_enjoy
        when :add    then q.enqueue { |_, fc, _| fc.add! mapping.second_to_first(file.rel_path), file }
        when :remove then q.enqueue { |_, _, sc| sc.remove! file }
        else raise "unreachable"
        end
      end
      diff.on_both do |first_file, second_file|
        case mapping.modified
        when :just_enjoy
        when :replace_first  then q.enqueue { |_, fc, _| fc.replace! first_file, second_file }
        when :replace_second then q.enqueue { |_, _, sc| sc.replace! second_file, first_file }
        when :compare
          q.enqueue do
            first_mtime  = first_file.mtime  # might block
            second_mtime = second_file.mtime # might block
            if first_mtime > second_mtime && mapping.modified_first == :update
              q.enqueue { |_, _, sc| sc.replace! second_file, first_file }
            elsif second_mtime > first_mtime && mapping.modified_second == :update
              q.enqueue { |_, fc, _| fc.replace! first_file, second_file }
            end
          end
        else raise "unreachable"
        end
      end
      diff.run_diff!(mapping.first_files, mapping.second_files) { |a, b| a.rel_path <=> b.rel_path }
    end
    
  end
  
end
