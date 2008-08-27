
require 'uri'
require File.join(File.dirname(__FILE__), 's3.rb')

class AmazonS3
  
  attr_writer :retries_count
  
  def initialize access_key, secret_key
    @access_key = access_key
    @secret_key = secret_key
    @retries_count = 10
  end
  
  def put_file bucket, key, file_path
    path_args = {}
    uri = URI::parse("https://s3.amazonaws.com:443/#{bucket}/#{key}")
    path = "#{uri.path}?#{uri.query}"

    file_size = File.size(file_path)
    File.open(file_path, 'r') do |file|
      with_automatic_retries do
        file.rewind
        http = Net::HTTP.new(uri.host, uri.port.to_i)
        http.use_ssl = (uri.scheme == 'https')
        http.start do
          req = Net::HTTP::Put.new("#{path}")
          req['x-amz-acl'] = 'public-read'
          req['content-length'] = "#{file_size}"
          set_aws_auth_header(req, @access_key, @secret_key, bucket, key, path_args)
          req.body_stream = file

          # if req.request_body_permitted?
          http.request(req)
        end
      end
    end
  end
  
private

  def with_automatic_retries
    retries_left = @retries_count
    loop do
      force_retry = false # true to retry even non-500 error codes
      response = nil
      begin
        response = yield
      rescue Errno::EPIPE => e
        force_retry = true
        $stderr.puts "Broken pipe: #{e}" 
      rescue Errno::ECONNRESET => e
        force_retry = true
        $stderr.puts "Connection reset: #{e}" 
      rescue Errno::ECONNABORTED => e
        force_retry = true
        $stderr.puts "Connection aborted: #{e}" 
      rescue Errno::ETIMEDOUT => e
        force_retry = true
        $stderr.puts "Connection timed out: #{e}"
      rescue Timeout::Error => e
        force_retry = true
        $stderr.puts "Connection timed out: #{e}" 
      rescue EOFError => e
        # i THINK this is happening like a connection reset
        force_retry = true
        $stderr.puts "EOF error: #{e}"
      rescue OpenSSL::SSL::SSLError => e
        force_retry = true
        $stderr.puts "SSL error: #{e}"
      end

      break if Net::HTTPOK === response
      break unless (response && (500...600).include?(response.code.to_i)) or force_retry
      retries_left -= 1
      if retries_left <= 0
        raise "Amazon S3 operation failed, #{@retries_count} retries did not help."
      end
    end
  end
  
  def set_aws_auth_header(request, aws_access_key_id, aws_secret_access_key, bucket='', key='', path_args={})
    # we want to fix the date here if it's not already been done.
    request['Date'] ||= Time.now.httpdate

    # ruby will automatically add a random content-type on some verbs, so
    # here we add a dummy one to 'supress' it.  change this logic if having
    # an empty content-type header becomes semantically meaningful for any
    # other verb.
    request['Content-Type'] ||= ''

    canonical_string =
    S3.canonical_string(request.method, bucket, key, path_args, request.to_hash, nil)
    encoded_canonical = S3.encode(aws_secret_access_key, canonical_string)

    request['Authorization'] = "AWS #{aws_access_key_id}:#{encoded_canonical}"
  end

end
