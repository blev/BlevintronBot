## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: Code to search archive.org for a replacement link.

require 'uri'
require 'config'
require 'retrieve'

ARCHIVE_SEARCH_PREFIX = "http://wayback.archive.org/web/"
ARCHIVE_HIT_SCHEMES = ['http']
ARCHIVE_HIT_PREFIX = "http://web.archive.org/web/"

WEBCITE_PREFIX = "http://webcitation.org"

def search_webcitation_org(oldurl, date_in, http_in=nil)
  search = URI.parse "#{WEBCITE_PREFIX}/query.php"
  args = {
    'url' => oldurl,
    'date' => (date_in.getutc.strftime "%Y-%m-%D %h:%m:%s"),
    'fromform' => '1',
    'submit' => 'Search' }

  code,body,cookie = retrieve_post search,args,http_in
  return [] if code != '200'
  return [] if cookie == nil

  top = URI.parse "#{WEBCITE_PREFIX}/topframe.php"
  body,xdate = retrieve_page top, http_in, {'Cookie'=>cookie}
  return [] if body == nil

  # extract the snapshot IDs from this document:
  #   <option value="1331141904939727">2012-03-07 12:38:24</option><o
  results = []
  body.scan(/<option value="(\d+)">(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})<\/option>/) do |match|
    id   = $1.to_i
    year = $2.to_i
    mon  = $3.to_i
    day  = $4.to_i
    hour = $5.to_i
    min  = $6.to_i
    sec  = $7.to_i

    found = "#{WEBCITE_PREFIX}/query?date=@0&fromform=1&id=#{id}"
    found_date = Time.utc(year,mon,day,  hour,min,sec)

    results << [found_date, found, 'webcitation.org']
  end
  results
end

# Check a query result.
# Turn the query result into a permalink.
# Return nil on failure.
def webcite_permalink(found_url, http_in)
  uri = URI.parse found_url
  page,date,cookie = retrieve_page(uri, http_in)
  return nil unless page

  return found_url
#  TODO
#  return nil unless cookie
#
#  top = URI.parse "#{WEBCITE_PREFIX}/topframe.php"
#  body,xdate = retrieve_page top, http_in, cookie
#  return nil unless body
#
#  puts body
#  body.scan /<a\s+href="([^"]+)"\s+[^>]*>Permalink/i do |match|
#    return "#{WEBCITE_PREFIX}/#{$1}"
#  end
#
#  nil
end

def search_archive_org_by_year(oldurl, year, http_in)
  search_year  = URI.parse(ARCHIVE_SEARCH_PREFIX + "#{year}*/" + oldurl)

  # Query archive.org
  body,xdate = retrieve_page search_year, http_in
  return [] unless body

  # Extract archive hits from this document
  hits = URI.extract(body, ARCHIVE_HIT_SCHEMES)
  hits.uniq!
  hits.delete_if {|u| not u.start_with? ARCHIVE_HIT_PREFIX }
  hits.delete_if {|u| not u.end_with? oldurl }

  # Extract the archive date from each URL
  results = []

  hits.each do |found|
    # Date is listed in the URL.
    year = found[ ARCHIVE_HIT_PREFIX.size+0,  4 ].to_i
    mon  = found[ ARCHIVE_HIT_PREFIX.size+4,  2 ].to_i
    day  = found[ ARCHIVE_HIT_PREFIX.size+6,  2 ].to_i
    hour = found[ ARCHIVE_HIT_PREFIX.size+8,  2 ].to_i
    min  = found[ ARCHIVE_HIT_PREFIX.size+10, 2 ].to_i
    sec  = found[ ARCHIVE_HIT_PREFIX.size+12, 2 ].to_i

    found_date = Time.utc(year,mon,day, hour,min,sec)

    results << [found_date, found, 'archive.org']
  end
  results
end

def search_archive_org(oldurl, date, http_in)
  hits = []

  y = date.year
  if date.month <= 6
    hits += search_archive_org_by_year(oldurl, y-1, http_in)
    hits += search_archive_org_by_year(oldurl,  y,  http_in)
  else
    hits += search_archive_org_by_year(oldurl,  y,  http_in)
    hits += search_archive_org_by_year(oldurl, y+1, http_in)
  end

  hits
end

# Returns [date, replacement-url]
# date error is in seconds >= 0
def find_archive_url(oldurl, date, search_archive_http_in=nil, confirm_archive_http_in=nil, webcite_http_in=nil)
  return [nil,nil] if date == nil

  begin
    # Find archives that fall in the +/- 6 month window
    hits = []
    hits += search_archive_org(oldurl, date, search_archive_http_in)
    hits += search_webcitation_org oldurl, date, webcite_http_in
    return [nil,nil] if hits.empty?

    # Sort by date error
    hits.sort! { |a1, a2| (date - a1[0]).abs <=> (date - a2[0]).abs }

#    # Diagnostic: print top five:
#    hits[0 ... 5].each do |found_date,found|
#      $log.puts "#{found_date} -- #{found}"
#    end

    # Now select the first hit which works
    hits.each do |found_date, found_url, source|
      case source
      when 'archive.org'
        # Issue a HEAD request to confirm that this link works.
        found_uri = URI.parse found_url
        fbody,fdate = retrieve_page found_uri, confirm_archive_http_in
        if fbody
          return [ found_date, found_url ]
        end

      when 'webcitation.org'
        # Retrieve it, and if successful, extract the permalink
        permalink = webcite_permalink found_url, webcite_http_in
        if permalink
          return [ found_date, permalink ]
        end
      end
    end

  rescue Exception => e
    $log.puts "Exception in find_archive_url: #{e}"
  end

  # None of the hits worked :(
  return [nil,nil]
end


# Find archive copies for several URLs
# Input: an array of pairs: [date,oldurl]
# Output: a map from oldurl to [date,replacement-url]
def find_archive_urls urls
  start_time = Time.now
  result = {}

  # Connect once
  reconnect(URI.parse ARCHIVE_SEARCH_PREFIX) do |archive_search_http|
    reconnect(URI.parse ARCHIVE_HIT_PREFIX) do |archive_confirm_http|
      reconnect(URI.parse WEBCITE_PREFIX) do |webcite_http|
        # Search all URLs
        urls.each do |date,url|
          rd, ru = find_archive_url url, date, archive_search_http, archive_confirm_http, webcite_http
          result[url] = [rd,ru] if ru
        end
      end
    end
  end

  urls.each do |date,url|
    rd,ru = result[url]
    if rd
      err = (date-rd).abs.to_f / 1.months

      $log.puts "found: '#{url}' @ #{date.wikitext_format}"
      $log.puts "    => '#{ru}' @ #{rd.wikitext_format}, err=#{sprintf "%.1f", err} months"
    end
  end

  $log.puts "Archive search took #{Time.now-start_time} seconds"
  result
end

