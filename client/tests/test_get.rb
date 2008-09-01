$:.unshift File.join(File.dirname(__FILE__), '..')

require 'ys_s3'
require 'tempfile'

t = Tempfile.new('amazon')
t.puts "Test"
t.flush

s3 = AmazonS3.new('1QPPZJR04QSS118WTS82', File.read(File.expand_path('~/.s3secret')).strip)
with_automatic_retries do
  s3.connect('updates.yoursway.com') do |c|
    puts "Uploading..."
    c.put_file 'test', t.path
    puts "Downloading..."
    
    t.close
    t = Tempfile.new("amazon2")
    
    c.get_into_file 'test', t.path
    puts t.read
    
    puts "Listing..."
    puts c.list
    
    puts "Deleting..."
    c.delete 'test'
    
    puts "Listing..."
    puts c.list
  end
end
$stderr.puts "done"
