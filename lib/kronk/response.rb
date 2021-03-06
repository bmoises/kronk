class Kronk

  ##
  # Standard Kronk response object.

  class Response

    class MissingParser < Kronk::Error; end
    class InvalidParser < Kronk::Error; end


    ENCODING_MATCHER = /(^|;\s?)charset=(.*?)\s*(;|$)/
    DEFAULT_ENCODING = "ASCII-8BIT"

    ##
    # Read http response from a file and return a Kronk::Response instance.

    def self.read_file path, opts={}, &block
      file = File.open(path, "rb")
      resp = new(file, opts)
      resp.body(&block)
      file.close

      resp
    end


    attr_reader :code, :io, :cookies, :headers
    attr_accessor :read, :request, :stringify_opts, :time, :conn_time

    ##
    # Create a new Response object from a String or IO.
    # Options supported are:
    # :request::        The Kronk::Request instance for this response.
    # :timeout::        The read timeout value in seconds.
    # :no_body::        Ignore reading the body of the response.
    # :force_gzip::     Force decoding body with gzip.
    # :force_inflate::  Force decoding body with inflate.
    # :allow_headless:: Allow headless responses (won't raise for invalid HTTP).

    def initialize input, opts={}, &block
      @request = opts[:request]
      @headers = {}
      @encoding = @parser = @body = @gzip = @gzip_io = nil

      @headless = false

      @stringify_opts = {}

      @raw  = ""
      @time = 0

      input ||= ""
      input = StringIO.new(input) if String === input

      @io = BufferedIO === input ? input : BufferedIO.new(input)

      @io.raw_output   = @raw
      @io.response     = self
      @io.read_timeout = opts[:timeout] if opts[:timeout]

      allow_headless = opts.has_key?(:allow_headless) ?
                        opts[:allow_headless] :
                        headless_ok?(@io.io)

      response_from_io @io, allow_headless

      @cookies = []

      Array(@headers['set-cookie']).each do |cvalue|
        cookie = CookieJar::CookieValidation.parse_set_cookie(cvalue).to_hash
        cookie.delete :version
        cookie.keys.each{|k| cookie[k.to_s] = cookie.delete(k) }
        @cookies << cookie
      end

      Array(@headers['set-cookie2']).each do |cvalue|
        cookie = CookieJar::CookieValidation.parse_set_cookie2(cvalue).to_hash
        cookie.keys.each{|k| cookie[k.to_s] = cookie.delete(k) }
        @cookies << cookie
      end

      Kronk.cookie_jar.set_cookies_from_headers uri, @headers unless
        opts[:no_cookies] || !(URI::HTTP === uri)

      self.gzip    = opts[:force_gzip]
      self.inflate = opts[:force_inflate]
      gzip?
      deflated?

      @read = !!opts[:no_body]
      body(&block) if block_given?
    end


    ##
    # Accessor for the HTTP headers []

    def [] key
      @headers[key.to_s.downcase]
    end


    ##
    # Setter for the HTTP headers []

    def []= key, value
      @headers[key.to_s.downcase] = value
    end


    ##
    # Returns the body of the response. Will wait for the socket to finish
    # reading if the body hasn't finished loading.
    #
    # If a block is given and the body hasn't been read yet, will iterate
    # yielding a chunk of the body as it becomes available.
    #
    # Note: Block will yield the full body if the response is compressed
    # using Deflate as the Deflate format does not support streaming.
    #
    #   resp = Kronk::Response.new io
    #   resp.body do |chunk|
    #     # handle stream
    #   end

    def body &block
      return @body if @read

      raise IOError, 'Socket closed.' if @io.closed?

      require 'zlib' if gzip? || deflated?

      error    = false
      last_pos = 0

      begin
        read_body do |chunk|
          chunk = chunk.dup
          chunk = unzip chunk if gzip?

          try_force_encoding chunk
          (@body ||= "") << chunk
          yield chunk if block_given? && !deflated?
        end

      rescue IOError, EOFError => e
        error    = e
        last_pos = @body.to_s.size

        @io.read_all
        @body = headless? ? @raw : @raw.split("\r\n\r\n", 2)[1]
        @body = unzip @body, true if gzip?
      end

      @body = Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(@body) if deflated?

      try_force_encoding @raw unless gzip? || deflated?
      try_force_encoding @body

      @read = true

      yield @body[last_pos..-1] if block_given? && (deflated? || error)

      @body
    end


    ##
    # If time was set, returns bytes-per-second for the whole response,
    # including headers.

    def byterate
      return 0 unless raw && @time.to_f > 0
      @byterate = self.total_bytes / @time.to_f
    end


    ##
    # Current size of the http body in bytes.

    def bytes
      self.raw_body.bytes.count
    end


    ##
    # Is this a chunked streaming response?

    def chunked?
      return false unless @headers['transfer-encoding']
      field = @headers['transfer-encoding']
      (/(?:\A|[^\-\w])chunked(?![\-\w])/i =~ field) ? true : false
    end


    ##
    # Get the content length header.

    def content_length
      return nil unless @headers.has_key?('content-length')
      len = @headers['content-length'].slice(/\d+/) or
          raise HTTPHeaderSyntaxError, 'wrong Content-Length format'
      len.to_i
    end


    ##
    # Assign the expected content length.

    def content_length= len
      unless len
        @headers.delete 'content-length'
        return nil
      end
      @headers['content-length'] = len.to_i.to_s
    end


    ##
    # Returns a Range object which represents the value of the Content-Range:
    # header field.
    # For a partial entity body, this indicates where this fragment
    # fits inside the full entity body, as range of byte offsets.

    def content_range
      return nil unless @headers['content-range']
      m = %r<bytes\s+(\d+)-(\d+)/(\d+|\*)>i.match(@headers['content-range']) or
          raise HTTPHeaderSyntaxError, 'wrong Content-Range format'
      m[1].to_i .. m[2].to_i
    end


    ##
    # The length of the range represented in Content-Range: header.

    def range_length
      r = content_range() or return nil
      r.end - r.begin + 1
    end


    ##
    # The extension or file type corresponding to the body,
    # based on the Content-Type. Defaults to 'txt' if none can be determined
    # or Content-Type is text/plain.
    #   application/json    => 'json'
    #   text/html           => 'html'
    #   application/foo+xml => 'xml'

    def ext
      file_ext =
        if headers['content-type']
          types = MIME::Types[headers['content-type'].sub(%r{/\w+\+}, '/')]
          types[0].extensions[0] unless types.empty?

        elsif uri
          File.extname(uri.path)[1..-1]
        end

      file_ext = "txt" if !file_ext || file_ext.strip.empty?
      file_ext
    end


    ##
    # Cookie header accessor.

    def cookie
      headers['cookie']
    end


    ##
    # Check if content encoding is deflated.

    def deflated?
      return !gzip? && @use_inflate unless @use_inflate.nil?
      @use_inflate = headers["content-encoding"] == "deflate" if
        headers["content-encoding"]
    end


    ##
    # Force the use of inflate.

    def inflate= value
      @use_inflate = value
    end


    ##
    # Return the Ruby-1.9 encoding of the body, or String representation
    # for Ruby-1.8.

    def encoding
      return @encoding if @encoding
      c_type = headers["content-type"].to_s =~ ENCODING_MATCHER
      @encoding = $2 if c_type
      @encoding ||= DEFAULT_ENCODING
      @encoding = Encoding.find(@encoding) if defined?(Encoding)
      @encoding
    end


    ##
    # Force the encoding of the raw response and body.

    def force_encoding new_encoding
      new_encoding = Encoding.find new_encoding unless Encoding === new_encoding
      @encoding = new_encoding
      try_force_encoding self.body
      try_force_encoding @raw
      @encoding
    end


    alias to_hash headers


    ##
    # If there was an error parsing the input as a standard http response,
    # the input is assumed to be a body.

    def headless?
      @headless
    end


    ##
    # The version of the HTTP protocol returned.

    def http_version
      @http_version
    end


    ##
    # Ruby inspect.

    def inspect
      content_type = headers['content-type'] || "text/plain"
      "#<#{self.class}:#{@code} #{content_type} \
#{total_bytes}/#{expected_bytes}bytes>"
    end


    ##
    # Check if connection should be closed or not.

    def close?
      @headers['connection'].to_s.include?('close') ||
      @headers['proxy-connection'].to_s.include?('close')
    end

    alias connection_close? close?


    ##
    # Check if connection should stay alive.

    def keep_alive?
      @headers['connection'].to_s.include?('Keep-Alive') ||
      @headers['proxy-connection'].to_s.include?('Keep-Alive')
    end

    alias connection_keep_alive? keep_alive?


    ##
    # Returns the body data parsed according to the content type.
    # If no parser is given will look for the default parser based on
    # the Content-Type, or will return the cached parsed body if available.

    def parsed_body new_parser=nil
      return unless body
      @parsed_body ||= nil

      return @parsed_body if @parsed_body && !new_parser

      new_parser ||= parser

      begin
        new_parser = Kronk.parser_for(new_parser) ||
                     Kronk.find_const(new_parser)
      rescue NameError
        raise InvalidParser, "No such parser: #{new_parser}"
      end if String === new_parser

      raise MissingParser,
        "No parser for: #{@headers['content-type']}" unless new_parser

      begin
        @parsed_body = new_parser.parse(self.body) or raise RuntimeError

      rescue MissingDependency
        raise

      rescue => e
        msg = ParserError === e ?
                e.message : "#{new_parser} failed parsing body"

        msg << " returned by #{uri}" if uri
        raise ParserError, msg
      end
    end


    ##
    # Returns the parsed header hash.

    def parsed_header include_headers=true
      out_headers = headers.dup
      out_headers['status']        = @code
      out_headers['http-version']  = http_version
      out_headers['set-cookie']  &&= @cookies.select{|c| c['version'].nil? }
      out_headers['set-cookie2'] &&= @cookies.select{|c| c['version'] == 1 }

      case include_headers
      when nil, false
        nil

      when Array, String
        include_headers = [*include_headers].map{|h| h.to_s.downcase}

        out_headers.keys.each do |key|
          out_headers.delete key unless
            include_headers.include? key.to_s.downcase
        end

        out_headers

      when true
        out_headers
      end
    end


    ##
    # The parser to use on the body.

    def parser
      @parser ||= Kronk.parser_for self.ext
    end


    ##
    # Assign the parser.

    def parser= parser
      @parser = Kronk.parser_for(parser) || Kronk.find_const(parser)
    rescue NameError
      raise InvalidParser, "No such parser: #{parser}"
    end


    ##
    # Returns the full raw HTTP response string after the full response
    # has been read.

    def raw
      body
      @raw
    end


    ##
    # Returns the body portion of the raw http response.

    def raw_body
      headless? ? @raw.to_s : @body.to_s
    end


    ##
    # Returns the header portion of the raw http response.

    def raw_header show=true
      return if !show || headless?
      headers = "#{@raw.split("\r\n\r\n", 2)[0]}\r\n"

      case show
      when Array, String
        includes = [*show].join("|")
        headers.scan(%r{^((?:#{includes}): [^\n]*\n)}im).flatten.join

      when true
        headers
      end
    end


    ##
    # Maximum time to wait on IO.

    def read_timeout
      @io.read_timeout
    end


    ##
    # Assign maximum time to wait for IO data.

    def read_timeout= val
      @io.read_timeout = val
    end


    ##
    # Returns the location to redirect to. Prepends request url if location
    # header is relative.

    def location
      return unless @headers['location']
      return @headers['location'] if !@request || !@request.uri
      @request.uri.merge @headers['location']
    end


    ##
    # Check if this is a redirect response.

    def redirect?
      @code.to_s =~ /^30\d$/
    end


    ##
    # Follow the redirect and return a new Response instance.
    # Returns nil if not redirect-able.
    # Supports all Request#new options, plus:
    # :trust_location:: Forwards HTTP auth to different host when true.

    def follow_redirect opts={}, &block
      return if !redirect?
      new_opts = @request ? @request.to_hash : {}

      if @code == "303" || @code == "302"
        new_opts[:http_method] = "GET"
        new_opts.delete(:form)
        new_opts.delete(:data)
      end

      new_opts.delete(:headers)
      new_opts.delete(:host)
      new_opts.delete(:path)

      new_opts.delete(:auth) if !opts[:trust_location] &&
        (!@request || self.location.host != self.uri.host)

      new_opts.merge!(opts)

      Request.new(self.location, new_opts).stream(new_opts, &block)
    end


    ##
    # Returns the raw response with selective headers and/or the body of
    # the response. Supports the following options:
    # :body:: Bool - Return the body; default true
    # :headers:: Bool/String/Array - Return headers; default true

    def to_s opts={}
      return raw if opts[:raw] &&
        (opts[:headers].nil? || opts[:headers] == true)

      str = opts[:raw] ? self.raw_body : self.body unless opts[:body] == false

      if opts[:headers] || opts[:headers].nil?
        hstr = raw_header(opts[:headers] || true)
        str  = [hstr, str].compact.join "\r\n"
      end

      str.to_s
    end


    ##
    # Returns the parsed response with selective headers and/or the body of
    # the response. Supports the following options:
    # :no_body:: Bool - Don't return the body; default nil
    # :show_headers:: Bool/String/Array - Return headers; default nil
    # :parser:: Object - The parser to use for the body; default nil
    # :transform:: Array - Action/path(s) pairs to modify data.
    #
    # Deprecated Options:
    # :ignore_data:: String/Array - Removes the data from given data paths
    # :only_data:: String/Array - Extracts the data from given data paths
    #
    # Example:
    #   response.data :transform => [[:delete, ["foo/0", "bar/1"]]]
    #   response.data do |trans|
    #     trans.delete "foo/0", "bar/1"
    #   end
    #
    # See Path::Transaction for supported transform actions in the
    # {ruby-path gem}[http://github.com/yaksnrainbows/ruby-path].

    def data opts={}, &block
      data = nil

      unless opts[:no_body]
        data = parsed_body opts[:parser]
      end

      if opts[:show_headers]
        header_data = parsed_header(opts[:show_headers])
        data &&= [header_data, data]
        data ||= header_data
      end

      Path::Transaction.run data, opts do |t|
        # Backward compatibility support
        t.select(*opts[:only_data])   if opts[:only_data]
        t.delete(*opts[:ignore_data]) if opts[:ignore_data]

        t.actions.concat opts[:transform] if opts[:transform]

        yield t if block_given?
      end
    end


    ##
    # Returns a String representation of the response, the response body,
    # or the response headers, parsed or in raw format.
    # Options supported are:
    # :parser:: Object/String - the parser for the body; default nil (raw)
    # :struct:: Boolean - Return data types instead of values
    # :only_data:: String/Array - extracts the data from given data paths
    # :ignore_data:: String/Array - defines which data points to exclude
    # :raw:: Boolean - Force using the unparsed raw response
    # :keep_indicies:: Boolean - indicies of modified arrays display as hashes.
    # :show_headers:: Boolean/String/Array - defines which headers to include
    #
    # If block is given, yields a Path::Transaction instance to make
    # transformations on the data. See Kronk::Response#data

    def stringify opts={}, &block
      opts = merge_stringify_opts opts

      if !opts[:raw] && (opts[:parser] || parser || opts[:no_body])
        data = self.data opts, &block
        DataString.new data, opts

      else
        self.to_s :body    => !opts[:no_body],
                  :headers => (opts[:show_headers] || false),
                  :raw     => opts[:raw]
      end

    rescue MissingParser
      if defined?(Cmd)
        ctype = @headers['content-type']
        Cmd.verbose "Warning: No parser for #{ctype} [#{uri}]"
      end

      self.to_s :body    => !opts[:no_body],
                :headers => (opts[:show_headers] || false),
                :raw     => opts[:raw]
    end


    def merge_stringify_opts opts # :nodoc:
      return @stringify_opts if opts.empty?

      opts = opts.dup
      @stringify_opts.each do |key, val|
        case key
        # Response headers - Boolean, String, or Array
        when :show_headers
          next if opts.has_key?(key) &&
                  (opts[key].class != Array || val == true || val == false)

          opts[key] = (val == true || val == false) ? val :
                                      [*opts[key]] | [*val]

        # String or Array
        when :only_data, :ignore_data
          opts[key] = [*opts[key]] | [*val]

        else
          opts[key] = val if opts[key].nil?
        end
      end
      opts
    end


    ##
    # Check if this is a 2XX response.

    def success?
      @code.to_s =~ /^2\d\d$/
    end


    ##
    # Check if the Response body has been read.

    def read?
      @read
    end


    ##
    # Number of bytes of the response including the header.

    def total_bytes
      return raw.bytes.count if @read
      return raw_header.bytes.count unless body_permitted?
      raw_header.to_s.bytes.count + bytes + 2
    end


    ##
    # Expected number of bytes to read from the server, including the header.

    def expected_bytes
      return raw.bytes.count if @read
      return raw_header.bytes.count unless body_permitted?
      raw_header.to_s.bytes.count + (content_length || range_length).to_i + 2
    end


    ##
    # The URI of the request if or the file read if available.

    def uri
      @request && @request.uri || File === @io.io && URI.parse(@io.io.path)
    end


    ##
    # Require the use of gzip for reading the body.

    def gzip= value
      @use_gzip = value
    end


    ##
    # Check if gzip should be used.

    def gzip?
      return @use_gzip unless @use_gzip.nil?
      @use_gzip = headers["content-encoding"] == "gzip" if
        headers["content-encoding"]
    end


    private


    ##
    # Check if the response should have a body or not.

    def body_permitted?
      Net::HTTPResponse::CODE_TO_OBJ[@code].const_get(:HAS_BODY) rescue true
    end


    ##
    # Check if a headless response is allowable based on the IO given
    # to the constructor.

    def headless_ok? io
      File === io || String === io || StringIO === io || $stdin == io
    end


    ##
    # Get response status and headers from BufferedIO instance.

    def response_from_io buff_io, allow_headless=false
      begin
        @http_version, @code, @msg = read_status_line buff_io
        @headers = read_headers buff_io

      rescue EOFError, Kronk::HTTPBadResponse
        raise unless allow_headless
        @http_version, @code, @msg = ["1.0", "200", "OK"]

        buff_io.rewind

        ctype = ["text/plain"]
        ctype = MIME::Types.of(buff_io.io.path).concat ctype if
          File === buff_io.io

        encoding = buff_io.io.respond_to?(:external_encoding) ?
                    buff_io.io.external_encoding : DEFAULT_ENCODING
        @headers = {
          'content-type' => "#{ctype[0]}; charset=#{encoding}",
        }

        @headless = true
      end

      @read = true unless body_permitted?
    end


    ##
    # Read the body from IO.

    def read_body target=nil
      block = lambda do |str|
        if block_given?
          yield str
        else
          target << str
        end
      end

      dest = Net::ReadAdapter.new block

      if chunked?
        read_chunked dest
        return
      end
      clen = content_length()
      if clen
        @io.read clen, dest, true   # ignore EOF
        return
      end
      clen = range_length()
      if clen
        @io.read clen, dest
        return
      end

      @io.read_all dest
    end


    ##
    # Unzip a chunk of the body being read.

    def unzip str, force_new=false
      return str if str.empty?

      @gzip_io = StringIO.new if !@gzip_io || force_new
      pos = @gzip_io.pos
      @gzip_io << str
      @gzip_io.pos = pos

      @gzip = Zlib::GzipReader.new @gzip_io if !@gzip || force_new

      @gzip.read rescue ""
    end


    ##
    # Read a chunked response body.

    def read_chunked dest
      len = nil
      total = 0
      while true
        line = @io.readline
        hexlen = line.slice(/[0-9a-fA-F]+/) or
            raise Kronk::HTTPBadResponse, "wrong chunk size line: #{line}"
        len = hexlen.hex
        break if len == 0
        begin
          @io.read len, dest
        ensure
          total += len
          @io.read 2   # \r\n
        end
      end
      until @io.readline.empty?
        # none
      end
    end


    ##
    # Read the first line of the response. (Stolen from Net::HTTP)

    def read_status_line sock
      str = sock.readline until str && !str.empty?
      m = /\AHTTP(?:\/(\d+\.\d+))?\s+(\d\d\d)\s*(.*)\z/in.match(str) or
        raise Kronk::HTTPBadResponse, "wrong status line: #{str.dump}"
      m.captures
    end


    ##
    # Read response headers. (Stolen from Net::HTTP)

    def read_headers sock
      res_headers = {}
      key = value = nil
      while true
        line = sock.readuntil("\n", true).sub(/\s+\z/, '')
        break if line.empty?
        if line[0] == ?\s or line[0] == ?\t and value
          value << ' ' unless value.empty?
          value << line.strip
        else
          assign_header(res_headers, key, value) if key
          key, value = line.strip.split(/\s*:\s*/, 2)
          key = key.downcase
          raise Kronk::HTTPBadResponse, 'wrong header line format' if value.nil?
        end
      end
      assign_header(res_headers, key, value) if key
      res_headers
    end


    def assign_header res_headers, key, value
      res_headers[key] = Array(res_headers[key]) if res_headers[key]
      Array === res_headers[key] ?
        res_headers[key] << value :
        res_headers[key] = value
    end


    ##
    # Assigns self.encoding to the passed string if
    # it responds to 'force_encoding'.
    # Returns the string given with the new encoding.

    def try_force_encoding str
      str.force_encoding encoding if str.respond_to? :force_encoding
      str
    end
  end
end
