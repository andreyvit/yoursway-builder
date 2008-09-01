
require 'uri'
require 'date'
require File.join(File.dirname(__FILE__), 's3.rb')

class HttpError < StandardError
  
  attr_reader :code
  
  class << self
    alias plain_new new
    def new code
      case code
      when 500...600 then Http5xxError.plain_new(code)
      else                HttpOtherError.plain_new(code)
      end
    end
  end
  
end

class Http5xxError < HttpError
  
end

class HttpOtherError < HttpError
  
end

module ObjectAdditions
  
  def with_automatic_retries retries_count=10
    retries_left = retries_count
    catch(:never) do
      begin
        return yield
      rescue StandardError => e
        raise if (retries_left -= 1) == 0
        $stderr.puts case e
          when Errno::EPIPE           then "Broken pipe: #{e}" 
          when Errno::ECONNRESET      then "Connection reset: #{e}" 
          when Errno::ECONNABORTED    then "Connection aborted: #{e}" 
          when Errno::ETIMEDOUT       then "Connection timed out: #{e}" 
          when Timeout::Error         then "Connection timed out: #{e}" 
          when EOFError               then "EOF error: #{e}" 
          when OpenSSL::SSL::SSLError then "SSL error: #{e}" 
          when Http5xxError           then "HTTP error #{e.code}"
          else raise
          end
        retry
      end
    end
  end
  
end

Object.send(:include, ObjectAdditions)

class AmazonS3
  
  attr_writer :retries_count
  
  def initialize access_key, secret_key
    @access_key = access_key
    @secret_key = secret_key
    @retries_count = 10
  end
  
  def connect bucket, key_prefix=''
    http = Net::HTTP.new("s3.amazonaws.com", 443)
    http.use_ssl = true
    http.start do
      yield AmazonS3Connection.new(@access_key, @secret_key, bucket, key_prefix, http)
    end
  end

  def get_file bucket, key, file_path
    with_automatic_retries(@retries_count) do
      connect(bucket) do |c|
        c.get_into_file key, file_path
      end
    end
  end
 
  def put_file bucket, key, file_path
    with_automatic_retries(@retries_count) do
      connect(bucket) do |c|
        c.put_file key, file_path
      end
    end
  end

end

class AmazonS3Connection
  
  def initialize access_key, secret_key, bucket, key_prefix, http
    @access_key = access_key
    @secret_key = secret_key
    @bucket = bucket
    @key_prefix = key_prefix
    @http = http
  end
  
  def get_into_file key, file_path
    begin
      File.open(file_path, 'wb') do |file|
        get_into_stream key, file
      end
    rescue
      File.unlink file_path
    end
  end
  
  def get_into_stream key, stream
    get(key) { |chunk| stream.write chunk }
  end
  
  def list
    parser = S3::ListBucketParser.new
    REXML::Document.parse_stream(raw_list, parser)
    parser.entries.collect { |e| AmazonS3File.new_from_entry(e) }
  end
  
  def raw_list
    path_args = {}
    req = Net::HTTP::Get.new("/#{@bucket}/")
    set_aws_auth_header(req, @access_key, @secret_key, @bucket, '', path_args)
    @http.request(req) do |response|
      raise HttpError.new(response.code) unless Net::HTTPOK === response
      return response.read_body
    end
  end
  
  def get key, &chunk_handler
    path_args = {}
    req = Net::HTTP::Get.new("/#{@bucket}/#{@key_prefix}#{key}")
    set_aws_auth_header(req, @access_key, @secret_key, @bucket, @key_prefix + key, path_args)
    @http.request(req) do |response|
      raise HttpError.new(response.code) unless Net::HTTPOK === response
      response.read_body(&chunk_handler)
    end
  end
  
  def delete key
    path_args = {}
    req = Net::HTTP::Delete.new("/#{@bucket}/#{@key_prefix}#{key}")
    set_aws_auth_header(req, @access_key, @secret_key, @bucket, @key_prefix + key, path_args)
    @http.request(req) do |response|
      raise HttpError.new(response.code) unless (200...300) === response.code.to_i
    end
  end
  
  def put_file key, file_path
    File.open(file_path, 'rb') do |file|
      put_stream key, File.size(file_path), file
    end
  end
  
  def put_stream key, file_size, stream
    path_args = {}
    uri = URI::parse("https://s3.amazonaws.com:443/#{@bucket}/#{@key_prefix}#{key}")
    path = "#{uri.path}?#{uri.query}"

    req = Net::HTTP::Put.new("#{path}")
    req['x-amz-acl'] = 'public-read'
    req['content-length'] = "#{file_size}"
    set_aws_auth_header(req, @access_key, @secret_key, @bucket, @key_prefix + key, path_args)
    set_keepalive_header req
    req.body_stream = stream
    response = @http.request(req)
    raise HttpError.new(response.code) unless Net::HTTPOK === response
  end
  
private
  
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
  
  def set_keepalive_header req
    req['Connection'] = 'keep-alive'
    req['Keep-Alive'] = '300'
  end
  
end

class AmazonS3File
  
  attr_reader :key, :mtime, :size
  
  def self.new_from_entry entry
    d = DateTime.parse(entry.last_modified)
    self.new(entry.key, Time.gm(d.year, d.month, d.day, d.hour, d.min, d.sec), entry.size)
  end
  
  def initialize key, mtime, size
    @key = key
    @mtime = mtime
    @size = size
  end
  
  def rel_path; key; end
  
  def to_s
    "#{@key} (size = #{@size}, mtime = #{@mtime})"
  end
  
end
