require 'rubygems'

require 'json'
require 'cookiejar'
require 'httpclient'

require 'thread'
require 'stringio'
require 'base64'

require 'net/https'
require 'optparse'
require 'yaml'

class Kronk

  # This gem's version.
  VERSION = '1.7.0'

  require 'kronk/constants'
  require 'kronk/player'
  require 'kronk/player/output'
  require 'kronk/player/suite'
  require 'kronk/player/stream'
  require 'kronk/player/benchmark'
  require 'kronk/player/request_parser'
  require 'kronk/player/input_reader'
  require 'kronk/cmd'
  require 'kronk/path'
  require 'kronk/path/path_match'
  require 'kronk/path/matcher'
  require 'kronk/path/transaction'
  require 'kronk/data_string'
  require 'kronk/diff/ascii_format'
  require 'kronk/diff/color_format'
  require 'kronk/diff/output'
  require 'kronk/diff'
  require 'kronk/response'
  require 'kronk/request'
  require 'kronk/plist_parser'
  require 'kronk/xml_parser'


  ##
  # Read the Kronk config hash.

  def self.config
    @config ||= DEFAULT_CONFIG
  end


  ##
  # Load a config file and apply to Kronk.config.

  def self.load_config filepath=DEFAULT_CONFIG_FILE
    conf = YAML.load_file filepath

    self.config[:requires].concat [*conf.delete(:requires)] if conf[:requires]

    [:content_types, :uri_options, :user_agents].each do |key|
      self.config[key].merge! conf.delete(key) if conf[key]
    end

    self.config.merge! conf
  end


  ##
  # Find a fully qualified ruby namespace/constant.

  def self.find_const name_or_file, case_insensitive=false
    return name_or_file unless String === name_or_file

    if name_or_file =~ /[^:]:([^:]+)$/
      req_file = $1
      i        = $1.length + 2
      const    = name_or_file[0..-i]

      begin
        require req_file
      rescue LoadError
        require File.expand_path(req_file)
      end

      find_const const

    elsif name_or_file.include? File::SEPARATOR
      begin
        require name_or_file
      rescue LoadError
        require File.expand_path(name_or_file)
      end

      namespace = File.basename name_or_file, ".rb"
      consts    = File.dirname(name_or_file).split(File::SEPARATOR)
      consts   << namespace

      name = ""
      until consts.empty?
        name  = "::" << consts.pop.to_s << name
        const = find_const name, true rescue nil
        return const if const
      end

      raise NameError, "no constant match for #{name_or_file}"

    else
      consts = name_or_file.to_s.split "::"
      curr = self

      until consts.empty? do
        const = consts.shift
        next if const.to_s.empty?

        if case_insensitive
          const.gsub!(/(^|[\-_.]+)([a-z0-9])/i){|m| m[-1,1].upcase}
          const = (curr.constants | Object.constants).find do |c|
            c.to_s.downcase == const.to_s.downcase
          end
        end

        curr = curr.const_get const.to_s
      end

      curr
    end
  end


  ##
  # Returns the config-defined parser class for a given content type.

  def self.parser_for content_type
    parser_pair =
      config[:content_types].select do |key, value|
        (content_type =~ %r{#{key}([^\w]|$)}) && value
      end.to_a

    return if parser_pair.empty?

    parser = parser_pair[0][1]
    parser = find_const parser if String === parser || Symbol === parser
    parser
  end


  ##
  # Deletes all cookies from the runtime.
  # If Kronk.run is in use, will write the change to the cookies file as well.

  def self.clear_cookies!
    @cookie_jar = CookieJar::Jar.new
  end


  ##
  # Returns the kronk cookie jar.

  def self.cookie_jar
    @cookie_jar ||= load_cookie_jar
  end


  ##
  # Load the saved cookies file.

  def self.load_cookie_jar file=nil
    file ||= config[:cookies_file]
    @cookie_jar = YAML.load_file file if File.file? file
    @cookie_jar ||= CookieJar::Jar.new
    @cookie_jar.expire_cookies
    @cookie_jar
  end


  ##
  # Save the cookie jar to file.

  def self.save_cookie_jar file=nil
    file ||= config[:cookies_file]
    File.open(file, "w") do |f|
      f.write @cookie_jar.to_yaml
    end
  end


  ##
  # Returns the Kronk history array of accessed URLs.

  def self.history
    path = self.config[:history_file]
    @history ||= File.read(path).split($/) if File.file?(path)
    @history ||= []
    @history
  end


  ##
  # Writes the URL history to the history file.

  def self.save_history
    history_str = self.history.uniq.join($/)

    File.open self.config[:history_file], "w" do |file|
      file.write history_str
    end
  end


  ##
  # See Kronk#compare. Short for:
  #   Kronk.new(opts).compare(uri1, uri2)

  def self.compare uri1, uri2, opts={}
    new(opts).compare uri1, uri2
  end


  ##
  # See Kronk#retrieve. Short for:
  #   Kronk.new(opts).retrieve(uri)

  def self.retrieve uri, opts={}
    new(opts).retrieve uri
  end


  attr_accessor :diff, :options, :response, :responses


  ##
  # Create a Kronk instance to keep references to all request, response,
  # and diff data.
  #
  # Supports the following options:
  # :data:: Hash/String - the data to pass to the http request
  # :query:: Hash/String - the data to append to the http request path
  # :follow_redirects:: Integer/Boolean - number of times to follow redirects
  # :headers:: Hash - extra headers to pass to the request
  # :http_method:: Symbol - the http method to use; defaults to :get
  # :user_agent:: String - user agent string or alias; defaults to 'kronk'
  # :auth:: Hash - must contain :username and :password; defaults to nil
  # :proxy:: Hash/String - http proxy to use; defaults to nil
  # :only_data:: String/Array - extracts the data from given data paths
  # :ignore_data:: String/Array - defines which data points to exclude
  # :keep_indicies:: Boolean - indicies of modified arrays display as hashes
  # :show_headers:: Boolean/String/Array - which headers to show in output
  # :parser:: Object/String - the parser to use for the body; default nil
  # :raw:: Boolean - run diff on raw strings

  def initialize opts={}
    @options   = opts
    @diff      = nil
    @responses = []
    @response  = nil
  end


  ##
  # Make requests, parse the responses and compare the data.
  # Query arguments may be set to the special value :cache to use the
  # last live http response retrieved.
  #
  # Returns a diff object.

  def compare uri1, uri2
    str1 = str2 = ""
    res1 = res2 = nil

    t1 = Thread.new do
          res1 = retrieve uri1
          str1 = res1.stringify
         end

    t2 = Thread.new do
          res2 = retrieve uri2
          str2 = res2.stringify
         end

    t1.join
    t2.join

    @responses = [res1, res2]
    @response  = res2

    opts = {:labels => [res1.uri, res2.uri]}.merge @options
    @diff = Diff.new str1, str2, opts
  end


  ##
  # Returns a Response instance from a url, file, or IO as a String.

  def retrieve uri
    options = Kronk.config[:no_uri_options] ? @options : options_for_uri(uri)

    if IO === uri || StringIO === uri
      Cmd.verbose "Reading IO #{uri}"
      resp = Response.new uri

    elsif File.file? uri.to_s
      Cmd.verbose "Reading file:  #{uri}\n"
      resp = Response.read_file uri

    else
      req = Request.new uri, options
      Cmd.verbose "Retrieving URL:  #{req.uri}\n"
      resp = req.retrieve
      Kronk.history << uri
    end

    resp.parser         = options[:parser] if options[:parser]
    resp.stringify_opts = options

    max_rdir = options[:follow_redirects]
    while resp.redirect? && (max_rdir == true || max_rdir.to_s.to_i > 0)
      Cmd.verbose "Following redirect..."
      resp     = resp.follow_redirect
      max_rdir = max_rdir - 1 if Fixnum === max_rdir
    end

    @responses = [resp]
    @response  = resp
    @diff      = nil

    resp

  rescue SocketError, Errno::ENOENT, Errno::ECONNREFUSED
    raise NotFoundError, "#{uri} could not be found"

  rescue Timeout::Error
    raise TimeoutError, "#{uri} took too long to respond"
  end


  ##
  # Returns merged config-defined options for a given uri.
  # Values in cmd_opts take precedence.
  # Returns cmd_opts Hash if none found.

  def options_for_uri uri
    out_opts = @options.dup

    Kronk.config[:uri_options].each do |matcher, opts|
      next unless (uri == matcher || uri =~ %r{#{matcher}}) && Hash === opts

      opts.each do |key, val|
        if out_opts[key].nil?
          out_opts[key] = val
          next
        end

        case key

        # Hash or uri query String
        when :data, :query
          val = Request.parse_nested_query val if String === val

          out_opts[key] = Request.parse_nested_query out_opts[key] if
            String === out_opts[key]

          out_opts[key] = val.merge out_opts[key], &DEEP_MERGE

        # Hashes
        when :headers, :auth
          out_opts[key] = val.merge out_opts[key]

        # Proxy hash or String
        when :proxy
          if Hash === val && Hash === out_opts[key]
            out_opts[key] = val.merge out_opts[key]

          elsif Hash === val && String === out_opts[key]
            val[:address] = out_opts[key]
            out_opts[key] = val

          elsif String === val && Hash === out_opts[key]
            out_opts[key][:address] ||= val
          end

        # Response headers - Boolean, String, or Array
        when :show_headers
          next if out_opts.has_key?(key) &&
                  (out_opts[key].class != Array || val == true || val == false)
          out_opts[key] = (val == true || val == false) ? val :
                                      [*out_opts[key]] | [*val]

        # String or Array
        when :only_data, :ignore_data
          out_opts[key] = [*out_opts[key]] | [*val]
        end
      end
    end

    out_opts
  end
end
