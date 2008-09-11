

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

$stdout.sync = true
$stderr.sync = true

require 'net/http'
require 'uri'
require 'optparse'

BUILDER_ROOT = File.expand_path(File.dirname(__FILE__))
Dir.chdir BUILDER_ROOT
$:.unshift File.join(BUILDER_ROOT, 'lib')

def is_windows?
  RUBY_PLATFORM =~ /(mswin|cygwin|mingw)(32|64)/
end

class Reloader
  
  def initialize
    @prev_length = $:.length
    @recorded_modules = []
  end
  
  def record! file_spec
    expanded_path = File.expand_path(file_spec)
    if expanded_path[0..BUILDER_ROOT.length-1] == BUILDER_ROOT && File.exists?(expanded_path)
      @recorded_modules << [expanded_path, File.mtime(expanded_path)]
    end
  end
  
  def record_all_required!
    file_specs = $"[@prev_length..-1]
    file_specs.each do |file_spec|
      record! file_spec
    end
  end
  
  def find_module_to_reload
    @recorded_modules.find { |file, mtime| File.mtime(file) != mtime }
  end
  
  def reload_needed?
    !!find_module_to_reload
  end
  
  def check_and_maybe_quit!
    if changes = find_module_to_reload
      file, mtime = changes
      puts "Restarting this builder because '#{file[BUILDER_ROOT.length+1..-1]}' has been changed on disk."
      puts
      exit! 22
    end
  end
  
end

$reloader = Reloader.new
require 'executor'
$reloader.record_all_required!
$reloader.record! __FILE__

class Config
  attr_accessor :server_host, :builder_name
  attr_accessor :poll_interval, :poll_interval_overriden
  attr_accessor :automatic_updates
end
config = Config.new
config.server_host = "builder.yoursway.com"
config.builder_name = "#{ENV['USER'] || ENV['LOGNAME'] || 'unknown'}@#{`hostname`.strip.gsub(/\..*$/, '')}"
config.builder_name = ENV['BUILDER_NAME'] unless (ENV['BUILDER_NAME'] || '').empty?
config.poll_interval = 59 # a default, will be overridden from the server
config.poll_interval_overriden = false
config.automatic_updates = (ENV['BUILDER_SELFUPDATE'] || 'false') == 'true'

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

  opts.on_tail("-p", "--poll SECONDS", Integer, "override poll interval (ignore the interval set by the server)") do |val|
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

puts
puts "=============================================================================="
puts "YourSway Builder build host"
puts
puts "Server:              #{config.server_host}"
puts "Builder name:        #{config.builder_name}"
puts "Builder version:     #{ENV['BUILDER_VERSION']}" if ENV['BUILDER_VERSION']
puts "Fixed poll interval: #{config.poll_interval} seconds" if config.poll_interval_overriden
puts "Automatic updates:   enabled" if config.automatic_updates
puts "=============================================================================="
puts

interrupted = false
# trap("INT") { interrupted = true }

class NetworkError < StandardError
end

class ServerCommunication
  
  attr_writer :retry_interval
  
  def initialize feedback, server_host, builder_name, retry_interval
    @builder_name = builder_name
    @server_host = server_host
    @obtain_work_uri = URI.parse("http://#{@server_host}/builders/#{@builder_name}/obtain-work")
    @retry_interval = retry_interval
  end
  
  def obtain_work
    post "Asking #{@server_host} to provide new jobs...",
      @obtain_work_uri, 'token' => 42
  end
  
  def job_done message_id, data
    post "Reporting job results to #{@server_host}...",
      message_done_uri(message_id), data.merge('token' => 42)
  end
  
  def send_console message_id, data
    begin
      body = try_network_operation do
        Net::HTTP.post_form message_progress_uri(message_id), 'console' => data
      end
      raise BuildAborted.new if body == "ABORT"
    rescue NetworkError => e
      puts "#{e.message}, could not send console log."
    end
  end
  
private

  def message_progress_uri(message_id)
    URI.parse("http://#{@server_host}/messages/%s/report_progress" % message_id)
  end

  def message_done_uri(message_id)
    URI.parse("http://#{@server_host}/builders/#{@builder_name}/messages/%s/done" % message_id)
  end

  def post(message, uri, vars = {})
    network_operation(message) do
      Net::HTTP.post_form(uri, vars)
    end
  end

  def network_operation message, &block
    begin
      puts message
      return try_network_operation(&block)
    rescue NetworkError => e
      puts e.message
      puts "Will retry in #{@retry_interval} seconds."
      sleep @retry_interval
      retry
    end
  end

  def try_network_operation
    begin
      response = yield
      return response.body if (200...300) === response.code.to_i
      raise NetworkError, "Server returned error response #{response.code}"
    rescue Errno::ECONNREFUSED => e
      raise NetworkError, "Connection refused: #{e}" 
    rescue Errno::EPIPE => e
      raise NetworkError, "Broken pipe: #{e}" 
    rescue Errno::ECONNRESET => e
      raise NetworkError, "Connection reset: #{e}" 
    rescue Errno::ECONNABORTED => e
      raise NetworkError, "Connection aborted: #{e}" 
    rescue Errno::ETIMEDOUT => e
      raise NetworkError, "Connection timed out: #{e}"
    rescue Timeout::Error => e
      raise NetworkError, "Connection timed out: #{e}" 
    rescue SocketError => e
      raise NetworkError, "Socket error: #{e}" 
    rescue EOFError => e
      raise NetworkError, "EOF error: #{e}"
    end
  end
  
end

class ConsoleFeedback
  
  def initialize
    @on_prev_line = false
  end
  
  def puts *data
    $stdout.puts if @on_prev_line
    $stdout.puts *data
    @on_prev_line = false
  end
  
  def start_job id
    puts "Starting job #{id}"
  end
  
  def start_command command, is_long
    return unless is_long
    puts
    puts "COMMAND: #{command}"
  end
  
  def action message
    puts
    puts "ACTION: #{message}"
  end
  
  def job_done id, options
    outcome = options[:outcome]
    failure_reason = options[:failure_reason]
    if outcome == 'SUCCESS'
      puts "Successfully finished job #{id}"
    elsif outcome == 'ABORTED'
      puts "Aborted per server request (job #{id})"
    else
      puts "FAILURE REASON (message id #{id})\n"
      puts "#{failure_reason}"
      puts "END FAILURE REASON (message id #{id})"
    end
  end
  
  def command_output output
    $stdout.print output
    @on_prev_line = !(output =~ /\n\Z/)
  end
  
  def command_still_running
  end
  
  def error message
    puts message
  end
  
  def info message
    puts message
  end
  
end

class FileFeedback
  
  def initialize file_name
    @file_name = file_name
    @file = File.open(file_name, 'w')
    @on_prev_line = false
  end
  
  def puts *data
    @file.puts if @on_prev_line
    @file.puts *data
    @on_prev_line = false
  end
  
  def start_job id
    @file.puts "Starting job #{id}"
  end
  
  def start_command command, is_long
    return unless is_long
    @file.puts
    @file.puts "COMMAND: #{command}"
    @file.flush
  end
  
  def action message
    @file.puts
    @file.puts "ACTION: #{message}"
    @file.flush
  end
  
  def job_done id, options
    outcome = options[:outcome]
    failure_reason = options[:failure_reason]
    if outcome == 'SUCCESS'
      @file.puts "Successfully finished job #{id}"
    elsif outcome == 'ABORTED'
      @file.puts "Aborted per server request (job #{id})"
    else
      @file.puts "FAILURE REASON (message id #{id})\n"
      @file.puts "#{failure_reason}"
      @file.puts "END FAILURE REASON (message id #{id})"
    end
    @file.close
  end
  
  def command_output output
    @file.print output
    @on_prev_line = !(output =~ /\n\Z/)
  end
  
  def command_still_running
  end
  
  def error message
    @file.puts message
    @file.flush
  end
  
  def info message
    @file.puts message
  end
  
  def close
    @file.close
  end
  
end

class BuildAborted < StandardError
end

class NetworkFeedback
  
  def initialize communicator
    @communicator = communicator
    @log_lines = []
    @last_time = nil
    @feedback_interval = 2
    @last_output_was_from_command = false
  end
  
  def start_job id
    @job_id = id
    @log_lines.push "", "Build started at #{Time.now.strftime("%c")} (message id #{id})."
    check_flush!
  end
  
  def add_lines! *lines
    @log_lines.push *lines
    @last_output_was_from_command = false
    check_flush!
  end
  alias add_line! add_lines!
  
  def check_flush!
    @log_lines = @log_lines[-20..-1] if @log_lines.length > 20
    now = Time.new
    if @job_id
      if @last_time.nil? || (now - @last_time >= @feedback_interval)
        @communicator.send_console @job_id, @log_lines.join("\n")
        @last_time = now
      end
    end
  end
  
  def start_command command, is_long
    return unless is_long
    add_lines! "", "COMMAND: #{command}"
  end
  
  def action message
    add_lines! "", "ACTION: #{message}"
  end
  
  def job_done id, options
    @communicator.job_done id, options
  end
  
  def command_output output
    lines = output.split("\n")
    if @last_output_was_from_command
      if !@log_lines.empty? && lines.first =~ /\r([^\r]+)\Z/
        @log_lines[-1] = $1
        lines.shift
      end
    end
    @last_output_was_from_command = !(lines.last =~ /\n\Z/)
    @log_lines.push *lines
    check_flush!
  end
  
  def command_still_running
    check_flush!
  end
  
  def error message
    add_line! "ERROR: #{message}"
  end
  
  def info message
    add_line! message
  end
  
end

class Multicast
  
  def initialize *targets
    @targets = targets
  end
  
  def with_target target
    @targets << target
    begin
      yield
    ensure
      @targets.delete target
      target.close
    end
  end
  
  def method_missing id, *args
    @targets.each { |t| t.send(id, *args) }
  end
  
end

feedback = ConsoleFeedback.new
comm = ServerCommunication.new(feedback, config.server_host, config.builder_name, config.poll_interval)

class ExecutionError < StandardError
end

def process_stage stage, commands, executor
  1.times do
    retry if catch(:repeat_stage) do
      executor.start_stage! stage
      commands.each { |command| executor.execute_command! stage,  command }
      executor.finish_stage! stage
    end
  end
end

def process_job feedback, builder_name, message_id, other_lines
  feedback.start_job message_id
  report = nil
  outcome = "SUCCESS"
  begin
    executor = Executor.new(builder_name, feedback)

    commands = []
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
  
      commands << executor.new_command(command, args, data)
    end

    process_stage :pure_set,   commands, executor
    
    executor.enable_references_expansion!
    process_stage :project,     commands, executor
    process_stage :set,         commands, executor
    process_stage :definitions, commands, executor
    
    prefix = executor.resolve_variable('build-files-prefix')
    descr_prefix = executor.resolve_variable('build-descr-prefix')
    log_item = executor.define_default_item! :file, 'build.log', "#{prefix}-buildlog.txt", ['log', 'featured'], "#{descr_prefix} Build Log"
    
    executor.determine_inputs_and_outputs! commands
    
    executor.allow_fetching_items!
    feedback.with_target(FileFeedback.new(log_item.fetch_locally(nil))) do
      process_stage :main,        commands, executor
    end
    
    executor.finish_build!
  rescue Interrupt
    outcome = "ABORTED"
    failure_reason = "User abort at the builder side"
  rescue BuildAborted
    outcome = "ABORTED"
    failure_reason = ""
  rescue Exception
    outcome = "ERR"
    failure_reason = "#{$!.class.name}: #{$!.message}\n#{($!.backtrace || []).join("\n")}"
  end
  begin
    report = executor.create_report.collect { |row| row.join("\t") }.join("\n")
  rescue StandardError => e
    puts "ERROR CREATING REPORT: #{e}"
    report = ''
  end
  feedback.job_done message_id, :report => report, :outcome => outcome, :failure_reason => failure_reason
end

while not interrupted
  $reloader.check_and_maybe_quit!
  
  response_body = comm.obtain_work
  unless response_body.nil?
    first_line, *other_lines = response_body.split("\n")

    result = []
    message_id = nil
    
    command, *args = first_line.chomp.split("\t")
    command.upcase!
    unless ['IDLE', 'ENVELOPE', 'SELFUPDATE'].include?(command)
      feedback.error "Unknown command received (#{command}), initiating self-update in #{config.poll_interval} seconds."
      sleep config.poll_interval
      exit! 55
    end
      
    proto_ver = args[0]
    unless proto_ver == 'v1'
      feedback.error "Unsupported protocol version detected (#{proto_ver}), initiating self-update in #{config.poll_interval} seconds."
      sleep config.poll_interval
      exit! 55
    end
    
    case command
    when 'IDLE'
      new_interval = [60*20, args[1].to_i].min
      if !config.poll_interval_overriden && new_interval >= 10 && config.poll_interval != new_interval
        config.poll_interval = new_interval
        comm.retry_interval  = new_interval
        feedback.info "Poll interval set to #{config.poll_interval}"
      end
      
      feedback.info "No outstanding jobs, gonna be lazing for #{config.poll_interval} seconds."
      sleep config.poll_interval
    when 'SELFUPDATE'
      exit!(55)
    else
      message_id = args[1]
      process_job Multicast.new(feedback, NetworkFeedback.new(comm)), config.builder_name, message_id, other_lines
    end
  end
end
