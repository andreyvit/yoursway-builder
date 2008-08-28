

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
  attr_accessor :poll_interval, :poll_interval_overriden
end
config = Config.new
config.server_host = "localhost:8080"
config.builder_name = `hostname`.strip.gsub(/\..*$/, '')
config.poll_interval = 59 # a default, will be overridden from the server
config.poll_interval_overriden = false

OptionParser.new do |opts|
  opts.banner = "Usage: ruby worker.rb [options]"
  
  opts.on( "-s", "--server SERVER", String, "the address of the YourSway Builder server to connect to (host or host:port)" ) do |opt|
    config.server_host = opt
  end
  
  opts.on("-n", "--name NAME", String, "builder name (e.g. andreyvitmb)" ) do |opt|
    config.builder_name = opt
  end

  opts.on_tail("--default-poll SECONDS", Integer, "default poll interval (used only if the server is not reachable)") do |val|
    config.poll_interval = val
  end

  opts.on_tail("--poll SECONDS", Integer, "override poll interval (ignore the interval set by the server)") do |val|
    config.poll_interval = val
    config.poll_interval_overriden = true
  end

  opts.on_tail("-U", "Allow self-updating (git fetch, git reset --hard)") do
    # processed by the launcher script, has no effect here
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

class ExecutionError < Exception
end

def try_network_operation
  begin
    return yield
  rescue Errno::ECONNREFUSED => e
    $stderr.puts "Connection refused: #{e}" 
  rescue Errno::EPIPE => e
    $stderr.puts "Broken pipe: #{e}" 
  rescue Errno::ECONNRESET => e
    $stderr.puts "Connection reset: #{e}" 
  rescue Errno::ECONNABORTED => e
    $stderr.puts "Connection aborted: #{e}" 
  rescue Errno::ETIMEDOUT => e
    $stderr.puts "Connection timed out: #{e}"
  rescue Timeout::Error => e
    $stderr.puts "Connection timed out: #{e}" 
  rescue EOFError => e
    $stderr.puts "EOF error: #{e}"
  end
  return nil
end

while not interrupted
  res = try_network_operation do
    Net::HTTP.post_form(obtain_work_uri, {'token' => 42})
  end
  wait_before_polling = true
  if res.nil?
    #
  elsif res.code.to_i != 200
    log "Error response: code #{res.code}"
  else
    first_line, *other_lines = res.body.split("\n")

    result = []
    message_id = nil
    
    command, *args = first_line.chomp.split("\t")
    command.upcase!
    if ['IDLE', 'ENVELOPE', 'SELFUPDATE'].include?(command)
      proto_ver = args[0]
      if proto_ver == 'v1'
        if command == 'IDLE'
          new_interval = [60*20, args[1].to_i].min
          if !config.poll_interval_overriden && new_interval >= 10 && config.poll_interval != new_interval
            config.poll_interval = new_interval
            log "Poll interval set to #{config.poll_interval}"
          end
          other_lines = []  # never execute
        elsif command == 'SELFUPDATE'
          exit!(55)
        else
          message_id = args[1]
          wait_before_polling = false
        end
      end
      
      if message_id
        report = nil
        outcome = "SUCCESS"
        begin
          load executor_rb
          executor = Executor.new(config.builder_name)
      
          until other_lines.empty?
            line = other_lines.shift.chomp
            next if line.strip.empty?
            next if line =~ /^\s*#/
        
            command, *args = line.split("\t")
            data = []
            until other_lines.empty?
              line = other_lines.shift.chomp
              next if line.strip.empty?
              next if line =~ /^\s*#/
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
        rescue Exception
          outcome = "ERR"
          failure_reason = "#{$!.class.name}: #{$!.message}\n#{($!.backtrace || []).join("\n")}"
          puts "FAILURE REASON (message id #{message_id})\n"
          puts "#{failure_reason}"
          puts "END FAILURE REASON (message id #{message_id})"
        end
        message_done_uri = URI.parse("http://#{config.server_host}/builders/#{config.builder_name}/messages/%s/done" % message_id)
        loop do
          res = try_network_operation do
            Net::HTTP.post_form(message_done_uri, {'token' => 42, 'report' => report, 'outcome' => outcome,
              'failure_reason' => failure_reason})
          end
          if res.nil?
            log "Could not post results, will repeat..."
          elsif res.code.to_i != 200
            log "Error posting results: code #{res.code}"
          else
            break
          end
          log "Will retry posting resuts in #{config.poll_interval} seconds"
          sleep config.poll_interval
        end
      end
    end
  end
  
  if wait_before_polling
    log "Sleeping for #{config.poll_interval} seconds"
    sleep config.poll_interval
  end
end
