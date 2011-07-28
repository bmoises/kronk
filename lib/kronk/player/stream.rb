class Kronk

  ##
  # Outputs Player results as a stream of Kronk outputs
  # in chunked form, each chunk being one response and the number
  # of octets being expressed in plain decimal form.
  #
  #   out   = Player::StreamOutput.new
  #
  #   io1   = StringIO.new "this is the first chunk"
  #   io2   = StringIO.new "this is the rest"
  #
  #   kronk = Kronk.new
  #   kronk.retrieve io1
  #   out.result kronk
  #   #=> "23\r\nthis is the first chunk\r\n"
  #
  #   kronk.retrieve io2
  #   out.result kronk
  #   #=> "16\r\nthis is the rest\r\n"
  #
  # Note: This output class will not render errors.

  class Player::Stream < Player::Output

    def result kronk
      output =
        if kronk.diff
          kronk.diff.formatted

        elsif kronk.response
          kronk.response.stringify kronk.options
        end

      output = "#{output.length}\r\n#{output}\r\n"
      $stdout << output
      $stdout.flush
      output
    end
  end
end
