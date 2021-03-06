
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
  FileUtils.mkdir_p File.join(*names[0..-2])
  File.open(File.join(*names), 'w') { |f| f.puts Time.now }
end

def test name

  puts
  puts name

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

def s3test name

  puts
  puts name

  dir1 = '/tmp/sync'

  FileUtils.rm_rf dir1

  FileUtils.mkdir_p dir1
  
  s3 = AmazonS3.new('1QPPZJR04QSS118WTS82', File.read(File.expand_path('~/.s3secret')).strip)
  s3p = S3Party.new(s3, 'updates.yoursway.com', 'test_', Foo.new)

  exp1, exp2 = yield dir1, s3p
  
  expected = [exp1.sort.join("\n"), '----', exp2.sort.join("\n")].join("\n")
  actual = [list_entries_recursively(dir1).sort.join("\n"), '----', s3p.list_files.collect { |f| f.rel_path }.sort.join("\n")].join("\n")

  if expected != actual
    
    puts "TEST FAILED:\n#{name}"
    puts
    puts "EXPECTED:\n#{expected}"
    puts
    puts "ACTUAL:\n#{actual}"
    
    fail
    
  end

end

class Foo
  
  def info *args
    puts "INFO #{args.collect {|x| x.to_s}.join("\n")}"
  end
  
end

include YourSway::Sync

test "Sync does nothing by default" do |dir1, dir2|
  write_file dir1, 'foo'
  
  m = SyncMapping.new('/', [], '/', [])
  YourSway::Sync.synchronize LocalParty.new(dir1, Foo.new), LocalParty.new(dir2, Foo.new), [m]
  
  [['foo'], []]
end

test "Sync adds files" do |dir1, dir2|
  write_file dir1, 'foo'
  
  m = SyncMapping.new('', [], '', [:add])
  YourSway::Sync.synchronize LocalParty.new(dir1, Foo.new), LocalParty.new(dir2, Foo.new), [m]
  
  [['foo'], ['foo']]
end

test "Sync appends to files" do |dir1, dir2|
  write_file dir1, 'foo'
  write_file dir2, 'foo'
  
  m = SyncMapping.new('', [], '', [:append])
  YourSway::Sync.synchronize LocalParty.new(dir1, Foo.new), LocalParty.new(dir2, Foo.new), [m]
  
  [['foo'], ['foo']]
end

test "Sync removes files" do |dir1, dir2|
  write_file dir2, 'foo'
  
  m = SyncMapping.new('', [], '', [:remove])
  YourSway::Sync.synchronize LocalParty.new(dir1, Foo.new), LocalParty.new(dir2, Foo.new), [m]
  
  [[], []]
end

test "Sync adds files with multiple mappings" do |dir1, dir2|
  write_file dir1, 'foo'
  write_file dir1, 'xx', 'bar'
  
  m1 = SyncMapping.new('', [], '', [:add])
  m2 = SyncMapping.new('xx', [], 'xx', [:add])
  YourSway::Sync.synchronize LocalParty.new(dir1, Foo.new), LocalParty.new(dir2, Foo.new), [m1, m2]
  
  [['foo', 'xx/', 'xx/bar'], ['foo', 'xx/', 'xx/bar']]
end

test "Sync adds and replaces files with multiple mappings" do |dir1, dir2|
  write_file dir1, 'foo'
  write_file dir1, 'xx', 'bar'
  write_file dir2, 'xx', 'bar'
  
  m1 = SyncMapping.new('', [], '', [:add])
  m2 = SyncMapping.new('xx', [], 'xx', [:add, :replace])
  YourSway::Sync.synchronize LocalParty.new(dir1, Foo.new), LocalParty.new(dir2, Foo.new), [m1, m2]
  
  [['foo', 'xx/', 'xx/bar'], ['foo', 'xx/', 'xx/bar']]
end

test "Sync adds and appends files with multiple mappings" do |dir1, dir2|
  write_file dir1, 'foo'
  write_file dir1, 'xx', 'bar'
  write_file dir2, 'xx', 'bar'
  
  m1 = SyncMapping.new('', [], '', [:add])
  m2 = SyncMapping.new('xx', [], 'xx', [:add, :append])
  YourSway::Sync.synchronize LocalParty.new(dir1, Foo.new), LocalParty.new(dir2, Foo.new), [m1, m2]
  
  [['foo', 'xx/', 'xx/bar'], ['foo', 'xx/', 'xx/bar']]
end

test "Sync replaces files" do |dir1, dir2|
  write_file dir1, 'foo'
  write_file dir2, 'foo'
  
  m = SyncMapping.new('', [], '', [:replace])
  YourSway::Sync.synchronize LocalParty.new(dir1, Foo.new), LocalParty.new(dir2, Foo.new), [m]
  
  [['foo'], ['foo']]
end

test "Sync updates files" do |dir1, dir2|
  write_file dir1, 'foo'
  write_file dir2, 'foo'
  
  m = SyncMapping.new('', [], '', [:update])
  YourSway::Sync.synchronize LocalParty.new(dir1, Foo.new), LocalParty.new(dir2, Foo.new), [m]
  
  [['foo'], ['foo']]
end

s3test "Sync uploads to S3" do |dir, s3|
  
  write_file dir, 'foo'

  m = SyncMapping.new('', [], '', [:add, :replace])
  YourSway::Sync.synchronize LocalParty.new(dir, Foo.new), s3, [m]
  
  [['foo'], ['foo']]
  
end

s3test "Sync appends to S3" do |dir, s3|
  
  write_file dir, 'foo'

  m = SyncMapping.new('', [], '', [:append, :replace])
  YourSway::Sync.synchronize LocalParty.new(dir, Foo.new), s3, [m]
  
  [['foo'], ['foo']]
  
end

s3test "Sync downloads from S3" do |dir, s3|
  
  m = SyncMapping.new('', [:add, :replace], '', [])
  YourSway::Sync.synchronize LocalParty.new(dir, Foo.new), s3, [m]
  
  [['foo'], ['foo']]
  
end

s3test "Deletes from S3" do |dir, s3|
  
  m = SyncMapping.new('', [], '', [:remove])
  YourSway::Sync.synchronize LocalParty.new(dir, Foo.new), s3, [m]
  
  [[], []]
  
end
