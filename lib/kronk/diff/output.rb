class Kronk::Diff

  ##
  # Renders diff outputs.

  class Output

    ##
    # Represents one diff section to render
    # (starts with @@-line,len +line,len@@)

    class Section
      attr_accessor :context, :format, :lindex, :rindex, :llen, :rlen,
                    :lmeta, :rmeta

      def initialize format, line_num_width=nil, lindex=0, rindex=0
        @format  = format
        @cwidth  = line_num_width
        @lindex  = lindex
        @rindex  = rindex
        @llen    = 0
        @rlen    = 0
        @lmeta   = nil
        @rmeta   = nil
        @lines   = []
        @context = 0
      end


      def << obj
        if String === obj
          add_common obj

        elsif Array === obj
          left, right = obj
          left.each{|o| add_left o }
          right.each{|o| add_right o }
        end
      end


      def add_common obj
        @llen    += 1
        @rlen    += 1
        @context += 1

        @lmeta ||= @rmeta ||= obj.meta.first if obj.respond_to? :meta

        line_nums =
          @format.lines [@llen+@lindex, @rlen+@rindex], @cwidth if @cwidth

        @lines << "#{line_nums}#{@format.common obj}"
      end


      def add_left obj
        @llen   += 1
        @context = 0

        @lmeta ||= obj.meta.first if obj.respond_to? :meta

        line_nums = @format.lines [@llen+@lindex, nil], @cwidth if @cwidth
        @lines << "#{line_nums}#{@format.deleted obj}"
      end


      def add_right obj
        @rlen   += 1
        @context = 0

        @rmeta ||= obj.meta.first if obj.respond_to? :meta

        line_nums = @format.lines [nil, @rlen+@rindex], @cwidth if @cwidth
        @lines << "#{line_nums}#{@format.added obj}"
      end


      def render
        cleft  = "#{@lindex+1},#{@llen}"
        cright = "#{@rindex+1},#{@rlen}"

        if @lmeta != @rmeta && @lmeta && @rmeta
          cleft  << " " << @lmeta
          cright << " " << @rmeta
        else
          info = @lmeta || @rmeta
        end

        [@format.context(cleft, cright, info), *@lines]
      end
    end


    ##
    # Returns a formatter from a symbol or string. Returns nil if not found.

    def self.formatter name
      return unless name

      return name        if Class === name
      return AsciiFormat if name == :ascii_diff
      return ColorFormat if name == :color_diff
      Kronk.find_const name rescue name
    end


    def self.attr_rm_cache *attrs # :nodoc:
      self.send :attr_reader, *attrs

      attrs.each do |attr|
        define_method "#{attr}=" do |value|
          if send(attr) != value
            instance_variable_set("@#{attr}", value)
            instance_variable_set("@cached", nil)
          end
        end
      end
    end


    attr_rm_cache :labels, :show_lines, :join_ch, :context, :format, :diff_ary

    def initialize diff, opts={}
      @output     = []
      @cached     = nil
      @diff       = diff

      @format =
        self.class.formatter(opts[:format] || Kronk.config[:diff_format]) ||
        AsciiFormat

      @context = Kronk.config[:context]
      @context = opts[:context] if opts[:context] || opts[:context] == false

      @join_ch = opts[:join_char] || "\n"

      @labels      = Array(opts[:labels])
      @labels[0] ||= "left"
      @labels[1] ||= "right"

      @show_lines = opts[:show_lines] || Kronk.config[:show_lines]
      @section    = false

      lines1 = diff.str1.lines.count
      lines2 = diff.str2.lines.count
      @cwidth = (lines1 > lines2 ? lines1 : lines2).to_s.length
    end


    def continue_section? i
       !@context || !!@diff_ary[i,@context+1].to_a.find{|da| Array === da}
    end


    def start_section? i
      !@section && continue_section?(i)
    end


    def end_section? i
      @section &&
        (i >= @diff_ary.length ||
         !continue_section?(i) && @context && @section.context >= @context)
    end


    def render force=false
      self.diff_ary = @diff.diff_array

      return @cached if !force && @cached
      @output << @format.head(*@labels)

      line1 = line2 = 0
      lwidth = @show_lines && @cwidth

      @diff_ary.each_with_index do |item, i|
        @section = Section.new @format, lwidth, line1, line2 if start_section? i
        @section << item if @section

        line1 += Array === item ? item[0].length : 1
        line2 += Array === item ? item[1].length : 1

        if end_section?(i+1)
          @output.concat @section.render
          @section = false
        end
      end

      @cached = @output.join(@join_ch)
    end

    alias to_s render
  end
end
