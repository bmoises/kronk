class Kronk

  ##
  # Outputs Player requests and results as a stream of Kronk outputs
  # separated by the null character \\000.
  #
  # Note: This output class will not render errors.

  class Player::StreamOutput

    attr_accessor :player_time

    def initialize
      @results     = []
      @player_time = 0
    end


    def result kronk
      output =
        if kronk.diff
          kronk.diff.formatted

        elsif kronk.response
          kronk.response.stringify kronk.options
        end

      output << "\0"
      $stdout << output
      $stdout.flush
    end


    def error err, kronk=nil
    end


    def completed
    end
  end
end
