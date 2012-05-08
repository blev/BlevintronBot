## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: liberal URI extraction and parsing

require 'uri'

module URI
  def self.liberal_extract(s, schemes=nil)
    # TODO
    URI.extract(s,schemes)
  end

  def self.liberal_parse(s)
    # TODO
    URI.parse(s)
  end
end


