
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: manipulating wikipedia markup

# Extracting links, comprehension of {{cite...}, etc

require 'nobots'
require 'uri'
require 'template'

class String

  # The canonical form for a string:
  #   - no leading whitespace
  #   - no trailing whitespace
  #   - all runs of whitespace converted to a single space
  #   - downcase
  def canon
    self.strip.gsub(/\s+/m, ' ').downcase
  end

  # Find each (non-overlapping) occurrence of 'pattern'
  # within this string. yield the integer offset of the
  # occurrence.
  # Search in reverse, so that iteration can continue
  # even when you modify later occurrences in the string.
  def each_occurrence pattern
    idx = size - 1
    while true
      idx = rindex(pattern, idx)
      break if idx == nil

      yield idx

      idx -= 1
    end
  end

  # This is similar to each_occurrence, however the pattern
  # must be a URL.  Further, it recognizes that the URL you
  # search for might be a substring of one of the URLs found
  # in the article.  This can happen for a few reasons:
  #   http://example.com is a substring of http://example.com/some/page
  #   http://example.com is a substring of http://web.archive.org/20040123011345/http://example.com
  # It avoids URLs which are substrings of a larger URL.
  def each_url_occurrence url
    # Lazy solution:
    # - Find all URLs
    all_urls = extract_urls self

    # - Identify confusing super urls
    strict_super_urls = all_urls.select {|u| (u.include? url) and (u != url) }

    # - Mark occurrences of super urls in this string
    bad_positions = {}
    strict_super_urls.sort {|x,y| x.size <=> y.size }.each do |super_url|
      each_occurrence(super_url) do |idx|
        # Mark every position within this occurrence as verbotten.
        for i in idx ... idx+super_url.size
          bad_positions[i] = super_url
        end
      end
    end

    # - yield only exact matches
    each_occurrence url do |idx|
      if bad_positions[idx]
#        $log.puts " - Skipping offset #{idx} because it's within super-url #{bad_positions[idx]}"
      else
        yield idx
      end
    end
  end

  # This is like include?, but does not match super-strings
  def include_url? url
    (extract_urls self).include? url.to_s
  end
end

def try_parse_date ad
  return nil if ad == nil

  # Guh... which format
  # - 9 Mar 2012?
  if ad =~ /^(\d{1,2})\s+([a-z]+),?\s+(\d{4})/i
    $log.puts "IMPLICIT preferred date format: dmy"
    Time.implicit_preferred_format = 'dmy'
    return Time.utc( $3.to_i, $2[0..2].downcase, $1.to_i )

  # - Mar 9, 2012?
  elsif ad =~ /^([a-z]+)\s+(\d{1,2}),?\s+(\d{4})/i
    $log.puts "IMPLICIT preferred date format: mdy"
    Time.implicit_preferred_format = 'mdy'
    return Time.utc( $3.to_i, $1[0..2].downcase, $2.to_i )

  # - 2012 February 16 ?
  elsif ad =~ /^(\d{4})\s+([a-z]+)\s+(\d{1,2})/i
    return Time.utc( $1.to_i, $2[0..2].downcase, $3.to_i )

  # - 2012-3-9 ? ambiguous. yyyy-mm-dd or yyyy-dd-mm ?
  elsif ad =~ /^(\d{4})-(\d{1,2})-(\d{1,2})/
    # we assume it's yyyy-mm-dd.
    return Time.utc( $1.to_i, $2.to_i, $3.to_i )
  end

  # It's really unbelievable all the date formats
  # that people have made up on wikipedia.
  ad.each_template do |tl|
    if tl.name == 'start date'
      begin
        pieces = tl.param_list.take(6).map {|s| s == '' ? nil : s.to_i }
        # TODO: timezone
        return Time.utc( *pieces )
      rescue Exception => e
        $log.puts "This is a nasty date: #{tl}"
      end
    elsif tl.name == 'date'
      begin
        date_field = tl.param_list.first
        return try_parse_date date_field
      rescue Exception => e
        $log.puts "Very nasty date: #{tl}"
      end
    end
    break
  end

  $log.puts "Can't parse date string: #{ad}"
  nil
end


NOPARSE_TAGS = ['nowiki', 'pre']

def remove_unparsed! string
  # First, remove comments
  while true
    first = string.index '<!--'
    break if first == nil

    last = string.index '-->', first
    break if last == nil

    len = last - first + 3
    string[ first,len] = (' '*len)
  end

  # Next, remove unparsed wikitext
  NOPARSE_TAGS.each do |tag|
    while true
      first = string.index(/<\s*#{tag}\s*>/mi)
      break if first == nil
      last = string.index(/<\s*\/\s*#{tag}\s*>/mi, first)
      break if last == nil

      close = string.index '>', last

      len = close - first + 1
      string[ first,len ] = (' '*len)
    end
  end
end

def is_unparsed? body,pattern,offset
  return true if enclosed_within_comment? body,pattern,offset

  NOPARSE_TAGS.each do |tag|
    return true if enclosed_within_tag? body,pattern,offset,tag
  end

  false
end

def enclosed_within_tag? body,pattern,offset, tag
  return false if offset == 0

  # Find the corresponding </tag>
  last = body.index(/<\s*\/\s*#{tag}\s*>/mi, offset)
  return false if last == nil
  return false if last < offset + pattern.size

  # Find the last <tag> which precedes the occurrence
  first = body.rindex(/<\s*#{tag}\s*>/mi, last)
  return false if first == nil
  return false if offset < first

  # We are enclosed in <tag>
  true
end

def enclosed_within_comment? body, pattern, offset
  # Find the corresponding -->
  last = body.index('-->', offset)
  return false if last == nil
  return false if last + 3 < offset + pattern.size

  # Find the last <!-- which precedes the occurrence
  first = body.rindex('<!--', last)
  return false if first == nil
  return false if offset < first + 4

  # We are enclosed in a comment
  true
end

def if_within_brackets body, pattern, offset
  # Find the corresponding ']'
  last = body.index(']', offset + pattern.size)
  return if last == nil

  # Find the last '[' which precedes the occurrence
  first = body.rindex('[', last)
  return if first == nil
  return if offset <= first

  unless is_unparsed? body, body[first..last], first
    yield [first,last]
  end
end

def if_within_template body, pattern, offset
  body.each_template :must_start_before=>offset, :must_end_after=>offset+pattern.size do |tl|
    if tl.start_offset < offset
      if offset + pattern.size < tl.end_offset+2
        return yield tl
      end
    end
  end
end

def if_followed_by_template body, pattern, offset
  body.each_template :must_start_after=>offset+pattern.size do |tl|
    if offset + pattern.size <= tl.start_offset
      between = body[ offset + pattern.size ... tl.start_offset ].strip
      if between == ''
        return yield tl
      end
    end
  end
end

def if_within_ref body, pattern, offset
  # Find the corresponding </ref>
  last = body.index(/<\s*\/\s*ref\s*>/i, offset + pattern.size)
  return if last == nil

  # Find first occurrence of <ref before the occurrence
  first = body.rindex(/<\s*ref/i, last)
  return if first == nil
  return if offset < first

  # TODO: <ref name="foo" />

  close = body.index('>', last)
  return if close == nil

  yield [first, close]
end

def if_within_table_row body,pattern,offset
  # Find either (i) next row "\n|-" or (ii) end of table "\n|}"
  next_row = body.index("\n|-", offset)
  end_table = body.index("\n|}", offset)
  last = [next_row, end_table].compact.min
  return if last == nil

  # Find either beginning of this row "\n|-"
  first = body.rindex("\n|-", last-1)
  return if first == nil
  return if offset < first

  yield [first, last]
end

# Pull all distinct URLs from the body of an article,
def extract_urls body
  # Look for URLs within this document.
  urls = URI.extract(body, ['http', 'https'])
  origSize = urls.size

  urls.uniq!
  urls.delete_if {|u| pathological_url? u }
  urls = urls.map {|u| remove_trailing_junk u }
  urls.uniq!

#  $log.puts " - Extracted #{urls.size}/#{origSize} URLs from this article"
  urls
end

# Pull links from the body of an article,
# excluding those which are known to be dead.
def scrape_article body
  urls = extract_urls body

  urls.delete_if {|uri| all_uses_dead_or_archived? body, uri }
  $log.puts " - Scraped #{urls.size} URLs from this article"
  urls
end

# Sometimes, Ruby's class URI shits itself.
# Examples seen in the wild:
#     http:/only.one/slash/after/scheme
#     http://HTTP://did.you.expect.a.port.number/after/that/colon?
def pathological_url? u
  begin
    uri = URI.parse u

    return true if uri.scheme == nil
    return true if uri.host == nil
    return true if uri.port == nil
    return true if uri.request_uri == nil

  rescue Exception => e
    return true
  end

  return false
end

# Correct the discrepancies between Ruby's URI.extract
# and Wikipedia's link extraction algorithm.
#
# This function is mostly an ugly hack
def remove_trailing_junk url
  # Ruby's URI::extract follows the spec precisely, and
  # allows URIs which contain closing braces ] and commas.
  #

  # See [[Help_talk:URL##Can_someone_clarify_link_behavior_with_parenthesis.3F]]
  # And MediaWiki source code for makeFreeExternalLink() at http://tinyurl.com/bpnj48w
  # lines 1238--1243

  while true
    next if url.chomp! '.'
    next if url.chomp! ','
    next if url.chomp! '\\'
    next if url.chomp! '!'
    next if url.chomp! '?'
    next if url.chomp! ';'
    next if url.chomp! ':'

    unless url.include? '('
      next if url.chomp! ')'
    end

    # Ugly, context-sensitive cases

    # This happens when Ruby's URI::extract sees
    # a bracket link
    next if url.chomp! ']'

    #           document               =>    URI.extract              =>     corrected
    #   http://foo.com'''title'''      => http://foo.com'''title'''   => http://foo.com
    #    ''http://en.wikipedia.org/''  => http://en.wikipedia.org/''  => http://en.wikipedia.org
    #   '''http://en.wikipedia.org/''' => http://en.wikipedia.org/''' => http://en.wikipedia.org
    #
    # We approximate this condition.  We will likely make fewer mistakes by
    # assuming that URLs do not end with ''' or ''
    if url =~ /^(.*?)'''.*$/
      url = $1
      next
    end

    if url =~ /^(.*?)''.*$/
      url = $1
      next
    end

    break
  end

  url
end

# Wikipedia already has a means to mark dead links.
# If a link is already marked dead, we will ignore it.
# If a link already has an alternate archive location, we will ignore it.
def all_uses_dead_or_archived? body, url
  # Find each use of this url in this body.
  # There may be more than one.
  body.each_url_occurrence url do |idx|
    unless this_use_dead_or_archived? body,url,idx
      return false
    end
  end

  true
end

def this_use_dead_or_archived? body,url,idx
  if_followed_by_template(body, url, idx) do |tag|
    # Marked dead by {{dead link}} following
    return true if tag.is_dead?
    return true if tag.is_archive?
  end

  if_within_brackets(body, url, idx) do |first,last|
    bracket_link = body[ first .. last ]
    if_followed_by_template(body, bracket_link, first) do |tag|
      return true if tag.is_dead?
      return true if tag.is_archive?
    end
  end

  if_within_template(body, url, idx) do |tag|
    return true if tag.is_dead?
    return true if tag.is_archive?

    if tag.is_citation?
      if tag['url'] == url and tag['archiveurl'] and tag['archiveurl'] != url
        return true
      end

      if_followed_by_template(body, tag.source, tag.start_offset) do |tag|
        return true if tag.is_dead?
        return true if tag.is_archive?
      end
    end
  end

  if_within_ref(body, url, idx) do |first,last|
    body[ first .. last ].each_template do |tag|
      return true if tag.is_dead?
      return true if tag.is_archive?
    end
  end

  # We should have eliminated these already, right?
  # No: when iterating via string.each_url_occurrence...
  return is_unparsed? body,url,idx
end

def extract_bracket_link_title str
  if str =~ /^\[(.*?)\]$/
    contents = $1.strip.split(/\s+/)
    url = contents.shift
    title = contents.join ' '
    return title
  end
  nil
end


def wiki_redirect? page
  if page =~ /\s*#REDIRECT\s*(.*)$/mi
    # Yes, it's a redirect
    target = $1.strip

    # A wiki link?
    if target =~ /^\[\[(.*?)\]\]$/mi
      # Yes, it's a wiki link
      target = $1.strip

      # Has title?
      before,sep,after = target.partition '|'
      if sep == '|'
        # Yes, it has a title
        return before.strip
      else
        return target
      end
    else
      return target
    end
  end
  nil
end


