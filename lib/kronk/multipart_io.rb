class Kronk

  class MultipartIO

    attr_reader :parts, :curr_part

    def initialize *parts
      @parts = parts.map do |part|
        if String === part
          StringIO.new part

        elsif part.respond_to?(:read)
          part

        else
          raise ArgumentError, "Invalid part #{part.inspect}"
        end
      end

      @curr_part = 0
    end


    def close
      @parts.each(&:close)
      nil
    end


    def read bytes=nil
      return if @parts.empty? || @curr_part.nil?
      return read_all if bytes.nil?

      buff = ""

      until @curr_part.nil?
        bytes = bytes - buff.bytes.count
        buff << @parts[@curr_part].read(bytes).to_s
        break if buff.bytes.count >= bytes

        @curr_part += 1
        @curr_part = nil if @curr_part >= @parts.length
      end

      return if buff.empty?
      buff
    end


    def read_all
      @parts.inject(""){|out, curr| out << curr.read}
    end


    def size
      total = 0

      @parts.each do |part|
        return nil unless part.respond_to?(:size) && part.size
        total += part.size
      end

      total
    end
  end
end
