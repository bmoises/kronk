class Kronk

  ##
  # Wraps an http response.

  class Response

  #TODO: implement redirect? and redirect!(follows=true) methods

    class MissingParser < Exception; end

    ##
    # Read http response from a file and return a HTTPResponse instance.

    def self.read_file path, options={}
      Kronk::Cmd.verbose "Reading file:  #{path}\n"

      options = options.dup
      resp    = nil

      File.open(path, "rb") do |file|
        resp = new file
      end

      resp
    end


    attr_accessor :body, :bytes, :request, :time, :headers, :raw

    ##
    # Create a new Response object from a String or IO.

    def initialize io=nil, res=nil, request=nil
      return unless io
      io = StringIO.new io if String === io

      # TODO: implement rescue for headless responses
      @_res     = res || request_from_io io
      @headers  = @_res.to_hash

      raw_req, raw_resp, bytes = read_raw_from io
      @bytes    = bytes.to_i
      @raw      = udpate_encoding raw_resp

      @request  = request || Request.parse update_encoding(raw_req)
      @time     = nil
      @encoding = nil

      @body     = udpate_encoding(@_res.body) if @_res.body
      @body   ||= @raw.split("\r\n\r\n",2)[1]
    end


    ##
    # Returns the encoding provided in the Content-Type header or
    # "binary" if charset is unavailable.
    # Returns "utf-8" if no content type header is missing.

    def encoding
      return @encoding if @encoding

      content_types = @_res.to_hash["content-type"]

      return @encoding = "utf-8" if !content_types

      content_types.each do |c_type|
        return @encoding = $2 if c_type =~ /(^|;\s?)charset=(.*?)\s*(;|$)/
      end

      @encoding = "binary"
    end


    ##
    # Returns the body data parsed according to the content type.
    # If no parser is given will look for the default parser based on
    # the Content-Type, or will return the cached parsed body if available.

    def parsed_body parser=nil
      @parsed_body ||= nil

      return @parsed_body if @parsed_body && !parser

      if String === parser
        parser = Kronk.parser_for(parser) || Kronk.find_const(parser)
      end

      parser ||= Kronk.parser_for @_res['Content-Type']

      raise MissingParser,
        "No parser for Content-Type: #{@_res['Content-Type']}" unless parser

      @parsed_body = parser.parse self.body
    end


    ##
    # Returns the parsed header hash.

    def parsed_header include_headers=true
      headers = @_res.to_hash.dup

      case include_headers
      when nil, false
        nil

      when Array, String
        include_headers = [*include_headers].map{|h| h.to_s.downcase}

        headers.each do |key, value|
          headers.delete key unless
            include_headers.include? key.to_s.downcase
        end

        headers

      when true
        headers
      end
    end


    ##
    # Returns the header portion of the raw http response.

    def raw_header include_headers=true
      headers = "#{@raw.split("\r\n\r\n", 2)[0]}\r\n"

      case include_headers
      when nil, false
        nil

      when Array, String
        includes = [*include_headers].join("|")
        headers.scan(%r{^((?:#{includes}): [^\n]*\n)}im).flatten.join

      when true
        headers
      end
    end


    ##
    # Returns the raw response with selective headers and/or the body of
    # the response. Supports the following options:
    # :no_body:: Bool - Don't return the body; default nil
    # :with_headers:: Bool/String/Array - Return headers; default nil

    def selective_string options={}
      str = @body unless options[:no_body]

      if options[:with_headers]
        header = raw_header(options[:with_headers])
        str = [header, str].compact.join "\r\n"
      end

      str
    end


    ##
    # Returns the parsed response with selective headers and/or the body of
    # the response. Supports the following options:
    # :no_body:: Bool - Don't return the body; default nil
    # :with_headers:: Bool/String/Array - Return headers; default nil
    # :parser:: Object - The parser to use for the body; default nil
    # :ignore_data:: String/Array - Removes the data from given data paths
    # :only_data:: String/Array - Extracts the data from given data paths

    def selective_data options={}
      data = nil

      unless options[:no_body]
        data = parsed_body options[:parser]
      end

      if options[:with_headers]
        data = [parsed_header(options[:with_headers]), data].compact
      end

      Path::Transaction.run data, options do |t|
        t.select(*options[:only_data])
        t.delete(*options[:ignore_data])
      end
    end


    private


    ##
    # Creates a Net::HTTPRequest instance from an IO instance.

    def request_from_io resp_io
      # On windows, read the full file and insert contents into
      # a StringIO to avoid failures with IO#read_nonblock
      if Kronk::Cmd.windows? && File === resp_io
        path = resp_io.path
        resp_io = StringIO.new io.read
        resp_io.instance_eval "def path; '#{path}'; end"
      end

      io = Net::BufferedIO === resp_io ? resp_io : Net::BufferedIO.new resp_io
      io.debug_output = socket_io = StringIO.new

      begin
        resp = Net::HTTPResponse.read_new io
        resp.reading_body io, true do;end

      rescue Net::HTTPBadResponse
        raise unless resp_io.respond_to? :path

        resp_io.rewind
        resp = HeadlessResponse.new resp_io.read, File.extname(resp_io.path)

      rescue EOFError
      end

      socket = resp.instance_variable_get "@socket"
      read   = resp.instance_variable_get "@read"

      resp.instance_variable_set "@socket", true unless socket
      resp.instance_variable_get "@read",   true

      resp
    end


    ##
    # Read the raw response from a debug_output instance and return an array
    # containing the raw request, response, and number of bytes received.

    def read_raw_from io
      req = nil
      resp = ""
      bytes = nil

      io.rewind
      output = io.read.split "\n"

      if output.first =~ %r{<-\s(.*)}
        req = instance_eval $1
        output.delete_at 0
      end

      if output.last =~ %r{read (\d+) bytes}
        bytes = $1.to_i
        output.delete_at(-1)
      end

      output.map do |line|
        next unless line[0..2] == "-> "
        resp << instance_eval(line[2..-1])
      end

      [req, resp, bytes]
    end


    ##
    # Assigns self.encoding to the passed string if
    # it responds to 'force_encoding'.
    # Returns the string given with the new encoding.

    def udpate_encoding str
      str.force_encoding self.encoding if str.respond_to? :force_encoding
      str
    end
  end



  ##
  # Mock response object without a header for body-only http responses.

  class HeadlessResponse

    include Response::Helpers

    attr_accessor :body, :code

    def initialize body, file_ext=nil
      @body = body
      @raw  = body

      encoding = body.encoding rescue "UTF-8"

      @header = {
        'Content-Type' => ["#{file_ext}; charset=#{encoding}"]
      }
    end


    ##
    # Interface method only. Returns nil for all but content type.

    def [] key
      @header[key]
    end

    def []= key, value
      @header[key] = value
    end


    ##
    # Interface method only. Returns empty hash.

    def to_hash
      Hash.new
    end
  end
end
