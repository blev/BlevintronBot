
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: wikipedia bot-exclusion templates and /robots.txt

require 'config'
require 'markup'

# Wikipedia restricts bot activities with the
# {{bots}} and {{nobots}} templates.
# Check if the given document body allows
# robot editing.
def wiki_forbids_bots? body
  body.each_template do |template|
    return true if template.name == 'nobots'

    if template.name == 'bots'
      template.each_param 'allow' do |k,allow|
        allow.downcase!

        return true if allow == 'none'
        return false  if allow  == 'all'

        return false if allow.include? BOT_NAME.downcase
        return false if allow.include? BOT_USERNAME.downcase
      end

      template.each_param 'deny' do |k,deny|
        deny.downcase!

        return true if deny == 'all'
        return false  if deny == 'none'

        return true if deny.include? BOT_NAME.downcase
        return true if deny.include? BOT_USERNAME.downcase
      end

      template.each_param 'optout' do |k,optout|
        optout.downcase!

        return true if optout == 'all'
        return false  if optout == 'none'

        return true if optout.include? BOT_NAME.downcase
        return true if optout.include? BOT_USERNAME.downcase
      end

    end
  end

  false
end

# Wikipedia allows editors to temporarily lock
# a page with {{In use}}.  It's a totally voluntary
# restriction and we honor it.
def wiki_in_use? body
  body.each_template do |template|
    return true if template.name == 'in use'
    return true if template.name == 'inuse'
  end
  false
end

# Determine if this page is a Bot user page.
# Specifically, check if it includes the {{Bot}} template
def wiki_is_bot_page? body
  body.each_template do |template|
    return true if template.name == 'bot'
  end
  false
end

def path_match(uri, pattern)
  # Support broken patterns that are full URIs
  if pattern.start_with? 'http://' or
     pattern.start_with? 'https://'
    begin
      u = URI.liberal_parse pattern # may throw
      return false if u.scheme != uri.scheme
      return false if u.host   != uri.host
      return false if u.port   != uri.port
      pattern = u.request_uri

    rescue Exception => e
      # guh. they listed a malformed uri...
    end
  end

  # Simplest case; hopefully the most common
  return true if uri.request_uri.start_with? pattern

  # Google and Yahoo introduced this.  It's effectively
  # a standard now, so we support it.
  if pattern.include? '*' or pattern.end_with? '$'
    # support patterns with the wildcard '*'
    # and the right-anchor '$'
    begin
      mypat = pattern.chomp '$'
      right_anchored = ( mypat != pattern )

      rgxstr = mypat.split('*').map {|x| Regexp.escape x }.join '.*'
      rgxstr << '$' if right_anchored

      rgx = Regexp.new rgxstr
      return ((uri.request_uri =~ rgx) != nil)

    rescue Exception => e
      # I think this is impossible, but who knows...
    end
  end

  false
end

class Scraper

  # Is a given path denied per /robots.txt ?
  # uri is a URI object corresponding to the
  # desired URL.  This method will (possibly) download
  # the robots.txt file, and then parse it to determine
  # if robots are allowed to visit the given URL.
  def robottxt_disallow?(uri, http)
    # Get a copy of /robots.txt with comments and
    # blank lines removed.
    lines = get_robotstxt(uri, http)

    # This is a somewhat conservative interpretation
    # of robots.txt
    # - In order, as opposed to longest match
    lines.each do |line| 
      # 'Allow: '
      if line.start_with? 'a '
        goodpath = line[ 2 .. -1 ].strip
        return false if path_match uri, goodpath

      # 'Disallow: '
      elsif line.start_with? 'd '
        badpath = line[ 2 .. -1 ].strip
        return true if path_match uri, badpath

      end
    end
    false
  end

private

  # Acquire a copy of robots.txt, either from the
  # network or from the local cache.  Also, manage
  # the cache to make sure it never grows too large.
  def get_robotstxt(uri, http)
    host = uri.host

    # Do we have a fresh, cached copy of robots.txt?
    if @robotstxt.has_key? host
      creationTime, lastUseTime, nUses, lines = hit = @robotstxt[host]

      unless expired? hit
        # Cache hit.  Update last use time and num uses.
        @robotstxt[host] = [creationTime, Time.now, nUses+1, lines]
        robots_dirty!
        return lines
      end
    end

    # Fetch robots.txt via HTTP
    robots = uri.dup
    robots.path = '/robots.txt'
    robots.query = robots.fragment = nil

    body,date = retrieve_page robots, http, {}, :silent
    body ||= ''

    # Record only the directives that we understand,
    # and which apply to this bot.
    # Use in a compact representation.
    lines = []
    echoMode = true
    body.each_line do |line|
      # Remove comments; skip blank lines
      line.sub!(/#.*$/, '')
      line.strip!
      next if line == ''

      # Does this user-agent string apply to us?
      if line =~ /^User-agent:(.*)$/i
        currentBot = $1.strip.downcase
        echoMode = (currentBot == '*' or currentBot.include? BOT_NAME.downcase)
      end

      # Skip directives which do not apply to us.
      next unless echoMode

      # The 'disallow nothing' directive => 'Allow: /'
      if line =~ /^Disallow:\s*$/i
        lines << "a /"

      # Do we understand this directive?
      elsif line =~ /^Allow:\s*(.*)$/i
        # From now on, new entries will use
        # this more compact representation 'a' for 'Allow: '
        lines << "a #{$1}"

      elsif line =~ /^Disallow:\s*(.*)$/i
        # From now on, new entries will use
        # this more compact representation 'd' for 'Disallow: '
        lines << "d #{$1}"
      end

    end

    # Don't let cache grow too large
    manage_robotstxt

    # Add this new record to our cache.
    creationTime = lastUseTime = Time.now
    @robotstxt[host] = [creationTime, lastUseTime, 1, lines]
    robots_dirty!
    return lines
  end

  # Manage the cache if it grows too large.
  def manage_robotstxt
    return if @robotstxt.size <= MAX_ROBOTSTXT_CACHE_SIZE

    $log.print "(Pruning robots.txt cache #{@robotstxt.size}"

    # First, remove expired entries
    @robotstxt.delete_if { |key,val| expired? val }

    # If still too large
    if @robotstxt.size > MAX_ROBOTSTXT_CACHE_SIZE

      # Determine average fitness
      sumFitness = 0
      numFitness = 0
      @robotstxt.each_pair do |key,entry|
        f = fitness(entry)

        sumFitness += f
        numFitness += 1
      end
      averageFitness = sumFitness / numFitness

      # Remove below-average entries
      # until it's small enough
      @robotstxt.delete_if do |key,entry|
        @robotstxt.size > MIN_ROBOTSTXT_CACHE_SIZE and
          fitness(entry) < averageFitness
      end
    end

    robots_dirty!
    $log.print "-> #{@robotstxt.size}) "
  end

  def expired?(cache_entry)
    xxCreationTime, xxLastUseTime, xxNumUses, xxLines = cache_entry

    (Time.now - xxCreationTime) > ROBOTSTXT_TTL
  end

  def fitness(cache_entry)
    xxCreationTime, xxLastUseTime, xxNumUses, xxLines = cache_entry

    # We value those elements which are used most frequently.

    # Lifetime in hours, rounded down, bounded below.
    lifetime = (  (Time.now - xxCreationTime).to_f / 1.hours  ).floor
    lifetime = 1 if lifetime < 1

    # Uses per hour in cache.
    fitness = xxNumUses.to_f / lifetime

    fitness
  end


end
