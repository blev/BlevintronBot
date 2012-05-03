
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: search article history for the first revisions
## Description: to include a pattern.

require 'config'
require 'retrieve'
require 'markup'

# Unify strings, URIs and Regexp with a common interface
class Pattern
  attr_reader :payload

  def initialize(payload)
    @payload = payload
  end

  def =~ str
    case @payload
    when String
      str.include? @payload
    when URI
      str.include_url? @payload
    when Regexp
      @payload =~ str
    end
  end
end

# When we detect a revert edit, we search before that
# for the edit that was reverted.  We don't want to search
# forever, so we impose a small limit on that search.
REVERT_LOCALITY = 10

# Determine which revision(s) of this article
# introduced these patterns.  Basically, this runs
# several binary searches simultaneously.
#
# Input:
#   The article title
#   A list of patterns --- each is a String, URI, or Regexp
# Output:
#   A hash { pattern => [revid,time,author,comment] }
#
# For example:
#   search_history 'Mitt Romney', ['wife', 'son', 'daughter', 'Harvard', 'Bain']
# yields:
#   {"Harvard" =>[  2802157, Sun Mar 07 22:46:47 UTC 2004, "Xinoph",        ""],
#    "Bain"    =>[  6413416, Thu Sep 02 17:47:48 UTC 2004, "Ylee",          "Added first name, details of business life, some rewriting of speculation para"],
#    "son"     =>[  3064041, Wed Mar 17 08:37:03 UTC 2004, "Chrisn4255",    "Paragraph formatting.  Info about father."],
#    "wife"    =>[ 15816399, Sat Jun 25 16:41:52 UTC 2005, "Noitall",       "add family info"],
#    "daughter"=>[481876769, Wed Mar 14 17:07:52 UTC 2012, "Fat&amp;Happy", ""]}
#
# This assumes that all patterns appear in the latest revision.
# If a pattern does not appear in the latest revision, it will
# report that it was introduced in the latest revision (for instance,
# the result for 'daughter', above).
#
# This performs a lot of API calls to Wikipedia; use it sparingly.
#
def search_history( article, patterns_in, http_in = nil )
  start_time = Time.now

  # Patterns may be either Strings, URIs, or Regexps
  # Convert our patterns into a common form
  patterns = patterns_in.map {|x| Pattern.new x}

  introductions = {}
  nGetHistory = 0
  nGetArticle = 0
  revisions = []

  # We are going to make a lot of requests.
  # Combine them
  reconnect(INSECURE_API_URL,http_in) do |http|

    # Get the 500-or-so most recent edits.
    nGetHistory += 1
    revisions = retrieve_history article, http
    return [] if revisions == nil or revisions.empty?

    lower_bounds = {}
    upper_bounds = {}

    # All patterns were introduced by the latest copy.
    patterns.each do |pattern|
      upper_bounds[ pattern ] = revisions.size - 1
    end

    # Keep searching farther back in time
    # until we find a revision which does not contain
    # ANY of these patterns.
    while true
      return introductions if $cancel

      # Did these patterns exist before these revisions?
      oldest_revision_id = revisions.first[0]
      nGetArticle += 1
      oldest,date = retrieve_revision article, oldest_revision_id, http

      # Find out which patterns were introduced AFTER
      # the oldest revision
      patterns.each do |pattern|
        if lower_bounds.has_key? pattern
          next

        elsif pattern =~ oldest
          # If the pattern existed in the oldest revision
          # Then it was added before
          upper_bounds[pattern] = 0

        else
          # If the pattern did not exist in the oldest revision
          # then it was added later
          lower_bounds[pattern] = 0
        end
      end

      # Have we found a lower-bound for every pattern yet?
      break if lower_bounds.size == patterns.size

      # We have not.  This means that one or more patterns
      # was introduced before this range of history.

      # We must get more history.
      nGetHistory += 1
      more_revisions = retrieve_history article, http, nil, oldest_revision_id-1
      break if more_revisions == nil or more_revisions.empty?

      # Prepend to our list.  This changes
      # the index of revisions already in the list
      revisions = more_revisions + revisions

      # Update all lower/upper bounds
      # since indices have changed.
      patterns.each do |pattern|
        if lower_bounds.has_key? pattern
          lower_bounds[ pattern ] += more_revisions.size
        end
        if upper_bounds.has_key? pattern
          upper_bounds[ pattern ] += more_revisions.size
        end
      end
    end

    # For all patterns p, either
    #   we have a lower bound for p, or
    #   p was introduced in the first revision.
    patterns.each do |pattern|
      unless lower_bounds.has_key? pattern
        introductions[ pattern ] = 0
      end
    end

    # Until we know an introduction for EVERY pattern
    while patterns.size > introductions.size
      return introductions if $cancel

      # Select any pattern which is not yet determined.
      some_pattern = patterns.select {|pat| not introductions.has_key? pat}.first

      lo = lower_bounds[some_pattern]
      hi = upper_bounds[some_pattern]

      pivot = (lo + hi)/2
      pivot_revision = revisions[pivot][0]

      # Pivot the remaining patterns according to this.
      nGetArticle += 1
      text,date = retrieve_revision article, pivot_revision, http
      break if text == nil

      patterns.each do |pattern|
        next if introductions.has_key? pattern
        lo = lower_bounds[pattern]
        hi = upper_bounds[pattern]

        if lo <= pivot and pivot <= hi
          if pattern =~ text
            upper_bounds[pattern] = pivot
          else
            lower_bounds[pattern] = pivot
          end

          if lower_bounds[pattern] + 1 == upper_bounds[pattern]
            # We have found a revision that added this pattern
            intro_rev = upper_bounds[pattern]
            intro_summary = revisions[intro_rev][3]

            # Is this revision a revert?
            is_revert,rrevid,ruser = looks_like_revert? intro_summary
            unless is_revert
              # Perfect match
              introductions[pattern] = intro_rev
              next
            end

            # we should re-start the search /before/ that revision
            # so we can find the original introduction.
            $log.puts "This is a false introduction: #{intro_summary}"
            $log.puts " - Reverts revision #{rrevid}" if rrevid
            $log.puts " - Reverts user #{ruser}" if ruser
            successful_restart = false

            # scan backwards to find the revision that was reverted
            r = intro_rev - 1
            reverted_revision = r
            REVERT_LOCALITY.times do
              break if r < 0
              if revisions[r][0] == rrevid
#                $log.puts "(reverts #{revisions[r].join ', '})"
                reverted_revision = r
                break

              elsif revisions[r][2] == ruser
                # Vandalism comes in groups.
                # See: https://secure.wikimedia.org/wikipedia/en/w/index.php?title=Voorhees_Township,_New_Jersey&oldid=49029503
                # One revert may revert several consecutive edits from one user.
                REVERT_LOCALITY.times do
                  break unless revisions[r][2] == ruser
                  break if r < 0
#                  $log.puts "(reverts #{revisions[r].join ', '})"
                  reverted_revision = r
                  r -= 1
                end
                break

              end
              r -= 1
            end

            # If the reverted revision had removed the pattern,
            # then the pattern /should/ have existed /immediately before/ that.
            new_upper_bound = reverted_revision - 1
            # Test that hypothesis
            if new_upper_bound >= 0
              $log.puts " - Testing the revision immediately before the revert..."
              nGetArticle += 1
              text,date = retrieve_revision article, revisions[new_upper_bound][0], http
              if pattern =~ text
                $log.puts " * Looks good; restarting search!"
                upper_bounds[pattern] = new_upper_bound
                lower_bounds[pattern] = 0
                successful_restart = true
              else
                $log.puts " * Pattern doesn't exist in that version :("
              end
            end

            # Failing that, return the revert.
            introductions[pattern] = intro_rev unless successful_restart

          end
        end
      end
    end

  end

  # Finally, map the introduction indices
  # to revision 4-tuples
  result = {}
  introductions.each_pair do |pattern, idx|
    key = pattern.payload.to_s
    result[key] = revisions[idx]
    $log.puts "Pattern '#{key}' introduced in revision #{ revisions[idx].join ', ' }"
  end

  $log.puts "Found introduction for #{patterns.size} patterns across #{revisions.size} revisions"
  $log.puts "  using #{nGetHistory} get-revision-history calls and #{nGetArticle} get-article calls"
  $log.puts "  duration: #{Time.now-start_time} seconds"
  result
end



# Retrieve a list of revisions to this article
# The range can be limited at either end with
# either revision IDs or timestamps
# Returns an array of 4-tuples: [revision-id, revision-date, author, comment]
# Result ascending in time.
def retrieve_history(article, http_in=nil, earliestRevId = nil, latestRevId = nil, limit=500)
  begin
    args = {
      "action"    => "query",
      "prop"      => "revisions",
      "titles"    => article,
      "rvprop"    => "ids|timestamp|user|comment",
      "rvlimit"   => limit,
      "rvdir"     => "older"
    }

    case earliestRevId
    when Numeric
      args['rvendid'] = earliestRevId
    when Time
      args['rvend'] = earliestRevId.mediawiki
    end

    case latestRevId
    when Numeric
      args['rvstartid'] = latestRevId
    when Time
      args['rvstart'] = latestRevId.mediawiki
    end

    api_request INSECURE_API_URL,args,http_in do |xml|
      result = []
      xml.elements.each('/api/query/pages/page/revisions/rev') do |rev|
        revid = rev.attribute('revid').to_s.to_i
        timestamp = REXML::Text.unnormalize rev.attribute('timestamp').to_s
        time = nil
        if timestamp =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z/
          time = Time.utc( $1.to_i, $2.to_i, $3.to_i,  $4.to_i, $5.to_i, $6.to_i )
        else
          $log.puts "get_history: Can't parse timestamp #{timestamp}"
        end

        user    = REXML::Text.unnormalize rev.attribute('user').to_s
        comment = REXML::Text.unnormalize rev.attribute('comment').to_s

        result << [revid,time,user,comment]
      end

      $log.puts "- found #{result.size} revisions."
      return result.reverse
    end

  rescue Exception => e
    $log.puts "- exception in retrieve_history: #{e} #{e.backtrace}"
  end

  []
end

# Does this revision summary appear to be a revert?
# If so,
#   - If it appears to revert a revision id by a user, return [true,revid,username]
#   - If it appears to revert a revision id, return [true,revid,nil]
#   - If it appears to revert a user's edit, return [true,nil,username]
#   - If it reverts something, but we don't know what, [true,nil,nil]
# Otherwise, [false,nil,nil]
def looks_like_revert? summary
  if summary =~ /undid\s+revision\s+(\d+)\s+by\s*..Special.Contributions.(.*?)\|/i
    return [true,$1.to_i,$2]

  elsif summary =~ /undid\s+revision\s+(\d+)\s+/i
    return [true,$1.to_i,nil]

  elsif summary =~ /(revert|reverted|reverting|undo|undid|undoing|rv|rvs|rvv|rv\/v)([^t]|t[^o])+by\s*..Special.Contributions.(.*?)\|/i
    return [true,nil,$3]

  # See: https://secure.wikimedia.org/wikipedia/en/wiki/Wikipedia:ESL#Revert_to_a_previous_edit
  elsif summary =~ /(revert|reverted|reverting|undo|undid|undoing|rv|rvs|rvv|rv\/v)([^t]|t[^o])+by\s*(.*?)[:;]/i
    return [true,nil,$3]

  elsif summary =~ /(revert|reverted|reverting|undo|undid|undoing|rv|rvs|rvv|rv\/v)/i
    return [true,nil,nil]

  end

  [false,nil,nil]
end


