

# def post_multipart(host, selector, fields, files):
#     content_type, body = encode_multipart_formdata(fields, files)
#     h = httplib.HTTPConnection(host)
#     headers = {
#         'User-Agent': 'INSERT USERAGENTNAME',
#         'Content-Type': content_type
#         }
#     h.request('POST', selector, body, headers)
#     res = h.getresponse()
#     return res.status, res.reason, res.read()


require 'net/http'
require 'uri'
require 'optparse'

class Config
  attr_accessor :server_host, :builder_name
  attr_accessor :poll_interval
end
config = Config.new
config.server_host = "localhost:8080"
config.builder_name = `hostname`.strip.gsub(/\..*$/, '')
config.poll_interval = 59 # a default, will be overridden from the server

OptionParser.new do |opts|
  opts.banner = "Usage: ruby worker.rb [options]"
  
  opts.on( "-s", "--server SERVER", String, "the address of the YourSway Builder server to connect to (host or host:port)" ) do |opt|
    config.server_host = opt
  end

  opts.on_tail("--default-poll", Integer, "default poll interval (will be overriden from the server, so only if the server is not reached)") do |val|
    config.poll_interval = val
  end

  opts.on_tail("-H", "--help", "Show this message") do
    puts opts
    exit
  end

  opts.on_tail("--version", "Show version") do
    puts "unknown version"
    exit
  end
end.parse!

puts "YourSway Builder build host"
puts
puts "Please verify that the following is correct. Push Ctrl-C to stop this builder."
puts
puts "Server:        #{config.server_host}"
puts "Builder name:  #{config.builder_name}"
puts

interrupted = false
# trap("INT") { interrupted = true }

obtain_work_uri = URI.parse("http://#{config.server_host}/builders/#{config.builder_name}/obtain-work")

executor_rb = File.expand_path(File.join(File.dirname(__FILE__), 'executor.rb'))
load executor_rb

def log message
  puts message
end

def invoke cmd, *args
  args = [''] if args.empty?
  system(cmd, *args)
end

class ExecutionError < Exception
end

while not interrupted
  res = Net::HTTP.post_form(obtain_work_uri, {'token' => 42})
  wait_before_polling = true
  if res.code.to_i != 200
    log "Error response: code #{res.code}"
  else
    first_line, *other_lines = res.body.split("\n")

    result = []
    message_id = nil
    
    command, *args = first_line.chomp.split("\t")
    command.upcase!
    if ['IDLE', 'ENVELOPE'].include?(command)
      proto_ver = args[0]
      if proto_ver == 'v1'
        if command == 'IDLE'
          new_interval = [60*20, args[1].to_i].min
          if new_interval >= 10 && config.poll_interval != new_interval
            config.poll_interval = new_interval
            log "Poll interval set to #{config.poll_interval}"
          end
          other_lines = []  # never execute
        else
          message_id = args[1]
          wait_before_polling = false
        end
      end
      
      if message_id
        load executor_rb
        executor = Executor.new(config.builder_name)
      
        until other_lines.empty?
          line = other_lines.shift.chomp
          next if line.strip.empty?
        
          command, *args = line.split("\t")
          data = []
          until other_lines.empty?
            line = other_lines.shift.chomp
            next if line.strip.empty?
            if line[0..0] == "\t"
              data << line[1..-1].split("\t")
            else
              other_lines.unshift line
              break
            end
          end
        
          executor.execute command, args, data
        end
        
        report = executor.create_report.collect { |row| row.join("\t") }.join("\n")
        message_done_uri = URI.parse("http://#{config.server_host}/builders/#{config.builder_name}/messages/%s/done" % message_id)
        res = Net::HTTP.post_form(message_done_uri, {'token' => 42, 'report' => report})
      end
    end
  end
  
  if wait_before_polling
    log "Sleeping for #{config.poll_interval} seconds"
    sleep config.poll_interval
  end
end
