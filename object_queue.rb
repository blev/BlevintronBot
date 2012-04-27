## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: an inter-process communication queue for ruby objects

require 'md5'

class ObjectQueue
  def initialize
    @reader,@writer = IO.pipe
  end

  def close_sender
    @writer.close
    @writer = nil
  end

  def close_receiver
    @reader.close
    @reader = nil
  end

  def send obj
    begin
      # Marshall this object to a string.
      bytes = Marshal.dump(obj)

      len = bytes.size

      md5 = MD5.new
      md5 << bytes

      packet = "#{sprintf "%08x", len}#{bytes}#{md5.hexdigest}"

      @writer.syswrite packet
      $log.puts "Sent a #{obj.class.to_s} object, len=#{len}"

    rescue Exception => e
      $log.puts "Failed to send: #{e.to_s}"
    end
  end

  def receive
    begin
      return nil unless IO.select [@reader],nil,nil,0

      # Read 8-byte length field
      lenstrhex = @reader.sysread 8
      len = lenstrhex.hex

      # Read object body
      bytes = @reader.sysread len

      md5 = MD5.new
      md5 << bytes
      received_checksum = md5.hexdigest

      # Read object checksum
      checksum = @reader.sysread( received_checksum.size )
      if checksum != received_checksum
        $log.puts "Invalid checksum"
        return nil
      end

      obj = Marshal.load bytes
      $log.puts "Received a #{obj.class.to_s} object, len=#{len}"
      return obj

    rescue Exception => e
      $log.puts "Failed to receive: #{e.to_s}"
    end
  end
end

