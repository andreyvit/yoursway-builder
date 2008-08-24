

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

class Config
  attr_accessor :server_host, :builder_name
  attr_accessor :poll_interval
end
config = Config.new
config.server_host = "localhost:8080"
config.builder_name = "bar"

# a default, will be overridden from the server
config.poll_interval = 59

interrupted = false
trap("INT") { interrupted = true }

uri = URI.parse("http://#{config.server_host}/builders/obtain-work")

def log message
  puts message
end

def invoke cmd, *args
  args = [''] if args.empty?
  system(cmd, *args)
end

while not interrupted
  res = Net::HTTP.post_form(uri, {
      'name' => config.builder_name,
    })
  wait_before_polling = true
  if res.code.to_i != 200
    log "Error response: code #{res.code}"
  else
    first_line, *other_lines = res.body.split("\n")

    result = []
    message_id = nil
    
    command, *args = first_line.split("\t")
    command.upcase!
    if ['IDLE', 'ENVELOPE'].include?(command)
      proto_ver = args[0]
      if proto_ver == 'v1'
        if command == 'IDLE'
          new_interval = [60*20, args[1].to_i].min
          if new_interval >= 30 && config.poll_interval != new_interval
            config.poll_interval = new_interval
            log "Poll interval set to #{config.poll_interval}"
          end
          other_lines = []  # never execute
        else
          message_id = args[1]
          wait_before_polling = false
        end
      end
      
      other_lines.each do |line|
        next if (line = line.strip).empty?
        command, *args = line.split("\t")
        case command.upcase
        when 'SAY'
          log "Saying #{args[0]}"
          invoke('say', args[0])
        else
          log "Unknown command #{command}(#{args.join(', ')})"
        end
      end
      
    end
  end
  
  if wait_before_polling
    log "Sleeping for #{config.poll_interval} seconds"
    sleep config.poll_interval
  end
end
