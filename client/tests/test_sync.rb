
$:.unshift File.join(File.dirname(__FILE__), '..')

require 'commons'
require 'ys_s3'
require 'sync'
require 'fileutils'

def list_entries_recursively(path, prefix = '', result = [])
  Dir.open(path) do |dir|
    while entry = dir.read
      next if entry == '.' or entry == '..'
      child = File.join(path, entry)
      child_prefix = if prefix == '' then entry else File.join(prefix, entry) end
      if File.directory? child
        result << child_prefix + '/'
        list_entries_recursively child, child_prefix, result if File.directory? child
      else
        result << child_prefix
      end
    end
  end
  return result
end

def write_file(*names)
  File.open(File.join(*names), 'w') { |f| f.puts Time.now }
end

def test name

  dir1 = '/tmp/sync'
  dir2 = '/tmp/cnys'

  FileUtils.rm_rf dir1
  FileUtils.rm_rf dir2

  FileUtils.mkdir_p dir1
  FileUtils.mkdir_p dir2

  exp1, exp2 = yield dir1, dir2
  
  expected = [exp1.sort.join("\n"), '----', exp2.sort.join("\n")].join("\n")
  actual = [list_entries_recursively(dir1).sort.join("\n"), '----', list_entries_recursively(dir2).sort.join("\n")].join("\n")

  if expected != actual
    
    puts "TEST FAILED:\n#{name}"
    puts
    puts "EXPECTED:\n#{expected}"
    puts
    puts "ACTUAL:\n#{actual}"
    
    fail
    
  end

end

include YourSway::Sync

test "Sync does nothing by default" do |dir1, dir2|
  write_file dir1, 'foo'
  
  m = SyncMapping.new('/', [], '/', [])
  YourSway::Sync.synchronize LocalParty.new(dir1), LocalParty.new(dir2), [m]
  
  [['foo'], []]
end

test "Sync adds files" do |dir1, dir2|
  write_file dir1, 'foo'
  
  m = SyncMapping.new('', [], '', [:add])
  YourSway::Sync.synchronize LocalParty.new(dir1), LocalParty.new(dir2), [m]
  
  [['foo'], ['foo']]
end

test "Sync removes files" do |dir1, dir2|
  write_file dir2, 'foo'
  
  m = SyncMapping.new('', [], '', [:remove])
  YourSway::Sync.synchronize LocalParty.new(dir1), LocalParty.new(dir2), [m]
  
  [[], []]
end

test "Sync replaces files" do |dir1, dir2|
  write_file dir1, 'foo'
  write_file dir2, 'foo'
  
  m = SyncMapping.new('', [], '', [:replace])
  YourSway::Sync.synchronize LocalParty.new(dir1), LocalParty.new(dir2), [m]
  
  [['foo'], ['foo']]
end

test "Sync updates files" do |dir1, dir2|
  write_file dir1, 'foo'
  write_file dir2, 'foo'
  
  m = SyncMapping.new('', [], '', [:update])
  YourSway::Sync.synchronize LocalParty.new(dir1), LocalParty.new(dir2), [m]
  
  [['foo'], ['foo']]
end
