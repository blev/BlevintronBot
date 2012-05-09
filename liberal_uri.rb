## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: liberal URI extraction and parsing

require 'uri'

# not ready for prime time
EXPERIMENTAL_PARSER = false

module URI
  LIBERAL_REGEX = /https?:[^\s"<>\[\]]+/
  EXTERNAL_BRACKET_LINK_REGEX = /\[.*?\]/m

  def self.liberal_extract(s, schemes=nil)
    unless EXPERIMENTAL_PARSER
      return URI.extract(s,schemes)
    end

    results = []

    remnants = s.each_template(:redact_nested=>true) do |tem|
      tem.each_param_non_canon do |key,value|
        URI.liberal_extract_no_templates(value||key,results)
      end
    end

    URI.liberal_extract_no_templates(remnants, results)

    results
  end

  def self.liberal_extract_no_templates(s, results=[])
    # Redact internal wikilinks
    s.gsub!(/\[\[.*?\]\]/mi, '')

    # For-each bracketted external link
    while true
      match = EXTERNAL_BRACKET_LINK_REGEX.match(s)
      break if match == nil

      offset = match.begin(0)
      link = match.to_s

      url,title = extract_bracket_link link
      results << url if url

      s[ offset, link.size ] = ''
    end


    while true
      match = LIBERAL_REGEX.match(s)
      break if match == nil

      offset = match.begin(0)
      url = match.to_s

      results << url

      s = s[ (offset+url.size) .. -1 ]
    end
    results
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


def extract_bracket_link str
  if (str.start_with? '[') and (str.end_with? ']')
    innards = str[1...-1]
    url,sep,title = innards.partition(/\s+/m)

    if sep == ''
      return [innards,nil]
    else
      return [url,title]
    end
  end
  nil
end


