class Kronk

  # TODO: Add support for full HTTP Request parsing
  #       Only use Player when stream has more than 1 request
  #       Support output for diff and response suites (separated by \0?)
  #       Loadtest mode?

  class Player

    # Matcher to parse request from.
    # Assigns http method to $1 and path info to $2.
    LOG_MATCHER = %r{([A-Za-z]+) (/[^\s"]+)[\s"]*}

    attr_accessor :limit, :concurrency, :queue

    attr_reader :output

    ##
    # Create a new Player for batch diff or response validation.
    # Supported options are:
    # :concurrency:: Fixnum - The maximum number of concurrent requests to make
    # :limit:: Fixnum - The maximum number of requests to make

    def initialize opts={}
      @limit       = opts[:limit]
      @concurrency = opts[:concurrency]
      @concurrency = 1 if !@concurrency || @concurrency <= 0
      self.output  = opts[:output] || SuiteOutput.new

      @queue     = []
      @threads   = []
      @results   = []
      @io        = opts[:io]
      @io_parser = LOG_MATCHER

      @player_start_time = nil
    end


    ##
    # The kind of output to use. Typically SuiteOutput or StreamOutput.
    # Takes an output class or a string that represents a class constant.

    def output= new_output
      return @output = new_output.new if Class === new_output

      klass =
        case new_output
        when /^(Player::)?stream(Output)?$/i
          StreamOutput

        when /^(Player::)?suite(Output)?$/i
          SuiteOutput

        when String
          Kronk.find_const new_output
        end

      @output = klass.new if klass
    end


    ##
    # Adds kronk request hash options to queue.
    # See Kronk#compare for supported options.

    def queue_req kronk_opts
      @queue << kronk_opts
    end


    ##
    # Populate the queue by reading from the given IO instance and
    # parsing it into kronk options.
    #
    # Parser can be a..
    # * Regexp: $1 used as http_method, $2 used as path_info
    # * Proc: return value should be a kronk options hash.
    #   See Kronk#compare for supported options.
    #
    # Default parser is LOG_MATCHER.

    def from_io io, parser=nil
      @io = io
      @io_parser = parser if parser
    end


    ##
    # Process the queue to compare two uris.
    # If options are given, they are merged into every request.

    def compare uri1, uri2, opts={}
      process_queue do |kronk_opts, suite|
        return Cmd.compare(uri1, uri2, kronk_opts.merge(opts)) unless suite
        process_compare uri1, uri2, kronk_opts.merge(opts)
      end
    end


    ##
    # Process the queue to request uris.
    # If options are given, they are merged into every request.

    def request uri, opts={}
      process_queue do |kronk_opts, suite|
        return Cmd.request(uri1, uri2, kronk_opts.merge(opts)) unless suite
        process_request uri, kronk_opts.merge(opts)
      end
    end


    ##
    # Start processing the queue and reading from IO if available.

    def process_queue
      @results.clear

      trap 'INT' do
        @threads.each{|t| t.kill}
        @threads.clear
        output_results
        exit 2
      end

      # First check if we're only processing a single case.
      # If so, yield a single item and return immediately.
      @queue << request_from_io if @io
      if @queue.length == 1 && (!@io || @io.eof?)
        yield @queue.shift, false
        return
      end

      $stdout.puts "Started"
      @player_start_time = Time.now

      reader_thread = try_read_from_io

      count = 0

      until finished? count
        while @threads.length >= @concurrency || @queue.empty?
          sleep 0.1
        end

        kronk_opts = @queue.shift
        next unless kronk_opts

        @threads << Thread.new(kronk_opts) do |thread_opts|
          result = yield thread_opts, true

          @results << result
          $stdout  << result[0]
          $stdout.flush

          @threads.delete Thread.current
        end

        count += 1
      end

      @threads.each{|t| t.join}
      @threads.clear

      reader_thread.kill

      success = output_results
      exit 1 unless success
    end


    ##
    # Attempt to fill the queue by reading from the IO instance.
    # Starts a new thread and returns the thread instance.

    def try_read_from_io
      Thread.new do
        loop do
          break if !@io || @io.eof?
          next  if @queue.length >= @concurrency * 2

          max_new = @concurrency * 2 - @queue.length

          max_new.times do
            break if @io.eof?
            req = request_from_io
            @queue << req if req
          end
        end
      end
    end


    ##
    # Get one line from the IO instance and parse it into a kronk_opts hash.

    def request_from_io
      line = @io.gets.strip

      if @io_parser.respond_to? :call
        @io_parser.call line

      elsif Regexp === @io_parser && line =~ @io_parser
        {:http_method => $1, :uri_suffix => $2}

      elsif line && !line.empty?
        {:uri_suffix => line}
      end
    end


    ##
    # Returns true if processing queue should be stopped, otherwise false.

    def finished? count
      (@limit && @limit >= count) || @queue.empty? &&
      (!@io || @io && @io.eof?) && count > 0
    end


    ##
    # Process and output the results.

    def output_results
      player_time   = (Time.now - @player_start_time).to_f
      total_time    = 0
      bad_count     = 0
      failure_count = 0
      error_count   = 0
      err_buffer    = ""

      @results.each do |(status, time, text)|
        case status
        when "F"
          total_time    += time.to_f
          bad_count     += 1
          failure_count += 1
          err_buffer << "  #{bad_count}) Failure:\n#{text}"

        when "E"
          bad_count   += 1
          error_count += 1
          err_buffer << "  #{bad_count}) Error:\n#{text}"

        else
          total_time += time.to_f
        end
      end

      non_error_count = @results.length - error_count

      avg_time = total_time / non_error_count

      $stdout.puts "\nFinished in #{player_time} seconds.\n\n"
      $stderr.puts err_buffer
      $stdout.puts "#{@results.length} cases, " +
                   "#{failure_count} failures, #{error_count} errors"

      $stdout.puts "Avg Time: #{avg_time}"
      $stdout.puts "Avg QPS: #{non_error_count / player_time}"

      return bad_count == 0
    end


    ##
    # Run a single compare and return a result array.

    def process_compare uri1, uri2, opts={}
      status = '.'

      begin
        kronk   = Kronk.new opts
        diff    = kronk.compare uri1, uri2
        elapsed =
          (kronk.responses[0].time.to_f + kronk.responses[0].time.to_f) / 2

        if diff.count > 0
          status = 'F'
          return [status, elapsed, diff_text(kronk)]
        end

        return [status, elapsed]

      rescue => e
        status  = 'E'
        return [status, 0, error_text(kronk, e)]
      end
    end


    ##
    # Run a single request and return a result array.

    def process_request uri, opts={}
      status = '.'

      begin
        kronk   = Kronk.new opts
        resp    = kronk.retrieve uri
        elapsed = resp.time.to_f

        unless resp.code =~ /^2\d\d$/
          status = 'F'
          return [status, elapsed, status_text(kronk)]
        end

        return [status, elapsed]

      rescue => e
        status  = 'E'
        return [status, 0, error_text(kronk, e)]
      end
    end


    private

    def status_text kronk
      <<-STR
  Request: #{kronk.response.code} - #{kronk.response.uri}
  Options: #{kronk.options.inspect}

      STR
    end


    def diff_text kronk
      <<-STR
  Request: #{kronk.responses[0].code} - #{kronk.responses[0].uri}
           #{kronk.responses[1].code} - #{kronk.responses[1].uri}
  Options: #{kronk.options.inspect}
  Diffs: #{kronk.diff.count}

      STR
    end


    def error_text kronk, err
      <<-STR
#{err.class}: #{err.message}
  Options: #{kronk.options.inspect}

      STR
    end
  end
end
