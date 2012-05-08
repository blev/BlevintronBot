## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: liberal URI extraction and parsing

require 'uri'

module URI
  LIBERAL_REGEX = /https?:[^\s"<>\[\]]+/

  def self.liberal_extract(s, schemes=nil)
    # TODO
    URI.extract(s,schemes)
  end

  # RFCs 1738, 2396, and 3986 be damned.
  # This is closer to what wikipedia allows
  def self.liberal_parse(s)
    unless s =~ LIBERAL_REGEX
      raise "Bad URL #{s}"
    end

    scheme = userinfo = host = port = nil
    path = query = fragment = nil

    # First, the scheme
    scheme,colon,remainder = s.partition ':'
    unless colon == ':'
      raise "Bad URL #{s}"
    end

    unless remainder.start_with? '//'
      raise "Bad URL #{scheme}: *** #{remainder}"
    end
    remainder = remainder[2..-1]

    first_at = remainder.index '@'

    first_slash = remainder.index '/'
    first_huh = remainder.index '?'
    first_hash = remainder.index '#'

    end_userinfo_host = remainder.index(/[\/?#]/)
    if end_userinfo_host
      # There is a path/query/fragment after hostinfo

      if first_at and first_at < end_userinfo_host
        userinfo = remainder[0 ... first_at]
        hostinfo = remainder[first_at+1 ... end_userinfo_host]
      else
        hostinfo = remainder[0 ... end_userinfo_host]
      end
      remainder = remainder[end_userinfo_host .. -1]

      host,colon,port = hostinfo.partition ':'

      next_sep = remainder.index(/[#\?]/)
      if next_sep == nil
        path = remainder
      else
        sep = remainder[next_sep,1]

        if sep == '?'
          path,sep,remainder = remainder.partition '?'
          if remainder.include? '#'
            query,sep,fragment = remainder.partition '#'
          else
            query = remainder
          end
        else
          path,sep,fragment = remainder.partition '#'
        end
      end
    else
      # This url ends with host info

      if first_at
        userinfo,at,hostinfo = remainder.partition '@'
      else
        hostinfo = remainder
      end

      host,colon,port = hostinfo.partition ':'
    end

    if scheme == 'http'
      return URI::HTTP.new(scheme, userinfo, host, port, nil, path, nil, query, fragment)

    elsif scheme == 'https'
      return URI::HTTPS.new(scheme, userinfo, host, port, nil, path, nil, query, fragment)
    end
  end
end


