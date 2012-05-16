
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: code to characterize a link and attempts to fetch that link

# TODO: clean this up.

require 'net/http'
require 'net/https'
require 'liberal_uri'

require 'config'

# Represents an attempt to retrieve a webpage.
class RetrievalAttempt
  attr_reader :date, :code, :cookie, :redirect

  def initialize(cd = nil, r = nil, ck = false)
    @date = Time.now
    @code = cd
    @cookie = ck
    @redirect = r
  end

  def self.norobots
    RetrievalAttempt.new 'norobots'
  end

  def self.exc e
    ra = RetrievalAttempt.new e
    ra.fix_code!
    return ra
  end

  # Ensure that the @code field is a String.
  # Return true if changed.
  def fix_code!
    # This nightmare exists because in the long-long ago,
    # we stored our database with YAML, but now with Marshal.
    #
    #   Exceptions cannot be serialized via Marshal
    #     (hence, a need to change stuff)
    #   Exceptions can sort of be serialized via YAML, but
    #     it is a lossy conversion.
    #     (hence, ugly cases for Pre- and Post-serialization exceptions)
    #
    # Going forward, @code must be a String.
    case @code
    when String
      return false

    when SocketError
      if @code.message == 'getaddrinfo: Name or service not known'
        @code = 'DNS error'
        return true
      else
        @code = @code.to_s
        return true
      end

    when Errno::ETIMEDOUT
      @code = 'connection timeout'
      return true

    when Timeout::Error
      @code = 'connection timeout'
      return true

    when Errno::ECONNREFUSED
      @code = 'connection refused'
      return true

    else
      @code = @code.to_s

      # These cases are for exceptions which
      # have already been serialized and
      # deserialized with some combination
      # of YAML and Marshal.
      case @code
      when 'Errno::ECONNREFUSED'
        @code = 'connection refused'
      when 'Errno::ETIMEDOUT'
        @code = 'connection timeout'
      end
      return true
    end
  end



  def is_ok?
    code == '200' or code == 'norobots'
  end

  def is_redirect?
    code =~ /^3\d\d$/
  end

  def to_s
    if @redirect
      return "#{@code} => #{@redirect}"
    else
      return @code.to_s
    end
  end

  def is_dns_error?
    @code == 'DNS error'
  end

  def is_timeout_error?
    (@code == 'connection timeout') or (@code == 'read timeout')
  end

  def is_connection_timeout?
    @code == 'connection timeout'
  end

  def is_connection_refused_error?
    @code == 'connection refused'
  end

  def is_non_redirect_404?
    (@code == '404') and (@redirect == nil)
  end

  def is_5xx?
    code =~ /^5\d\d$/
  end


  def apologize
    if is_redirect? and cookie
      "    #{date}: redirect (#{code}) to #{redirect}, set cookies\n"
    elsif is_redirect? and not cookie
      "    #{date}: redirect (#{code}) to #{redirect}, no cookies set\n"
    else
      "    #{date}: #{code}\n"
    end
  end
end


# A link, its users, and all our attempts to retrieve it.
class Link
  attr_reader :url, :fragno

  def initialize(url)
    @fragno = Time.now.yday % NUM_FRAGMENTS
    @url = url
    @users = []
    @attempts = []
  end

  def add_user title
    @users << title
  end

  def articles
    @users.uniq!
    @users
  end

  def is_connection_timeout?
    @attempts.last.is_connection_timeout?
  end

  def next_check_time(base = nil)
    if is_new?
      base ||= Time.now
      return base - 1

    else
      return last_check_time + LINK_TRIAL_PERIOD
    end
  end

  def host
    u = URI.liberal_parse @url
    u.host
  end

  def last_check_time
    return nil if is_new?
    @attempts.last.date
  end

  def first_check_time
    return nil if is_new?
    @attempts.first.date
  end

  # A link can be classified in one of these cases
  #   
  #   is_young? - the link has not been tested enough.
  #   is_ok? - the link gave response 200 OK at least once.
  #   is_consistent_redirect? - the link is always an HTTP 3xx redirect to the same target.
  #   is_bad? - was never able to get a 200 or redirect.
  #   is_good_enough? - the link is a redirect, but not consistent.

  def is_young?
    not has_enough_samples?
  end

  def is_ok?
    @attempts.each do |attempt|
      return true if attempt.is_ok?
    end
    false
  end

  def is_consistent_redirect?
    return false unless has_enough_samples?
    return false unless @attempts.first.is_redirect?

    @attempts.each do |attempt|
      return false unless @attempts.first.redirect == attempt.redirect
    end

    (@attempts.first.redirect != nil)
  end

  def is_good_enough?
    return false unless has_enough_samples?

    @attempts.each do |attempt|
      return true if attempt.is_ok?
      return true if attempt.is_redirect?
    end
    return false
  end

  def is_bad?
    (not is_good_enough?) and has_enough_samples?
  end

  # Correctable types of bad links
  def cannot_be_fixed?
    not is_broken_with_high_confidence?
  end

  def is_broken_with_high_confidence?
    return false unless has_enough_samples?

    return (is_dns_error? or
            is_timeout_error? or
            is_connection_refused_error? or
            is_non_redirect_404? or
            is_5xx? )
  end

  def is_high_confidence_redirect?
    return false unless has_enough_samples?
    return false unless is_consistent_redirect?
    return false unless @code == '301'
    return false if @attempts.last.cookie

    src = URI.liberal_parse url
    dst = URI.liberal_parse redirect

    spath = src.request_uri
    dpath = dst.request_uri
    return true if spath == dpath and spath != '/'

    # Redirect to an error page, registration page, login page...
    return false if dpath =~ /404/         and spath !~ /404/
    return false if dpath =~ /error/i      and spath !~ /error/i
    return false if dpath =~ /regist/i     and spath !~ /regist/i
    return false if dpath =~ /login/i      and spath !~ /login/i
    return false if dpath =~ /not.?found/i and spath !~ /not.?found/i

    # Same host, but redirect to home page
    if src.scheme == dst.scheme and
       src.host   == dst.host   and
       src.port   == dst.port   and
       dpath      == '/'        and
       spath      != '/'
      return false
    end

    true
  end


  # Concrete types of bad links
  def is_dns_error?
    @attempts.each do |attempt|
      return false unless attempt.is_dns_error?
    end
    true
  end

  def is_timeout_error?
    @attempts.each do |attempt|
      return false unless attempt.is_timeout_error?
    end
    true
  end

  def is_connection_refused_error?
    @attempts.each do |attempt|
      return false unless attempt.is_connection_refused_error?
    end
    true
  end

  def is_non_redirect_404?
    @attempts.each do |attempt|
      return false unless attempt.is_non_redirect_404?
    end
    true
  end

  def is_5xx?
    @attempts.each do |attempt|
      return false unless attempt.is_5xx?
    end
    true
  end

  def redirect
    redir = @attempts.last.redirect

    # Sometimes a redirect is a path
    if redir.start_with? '/'
      # In that case, it inherits (scheme, host, port) from previous url.
      u = URI.liberal_parse @url

      if u.port == Net::HTTP.default_port
        redir = "#{ u.scheme }://#{ u.host }#{ redir }"
      else
        redir = "#{ u.scheme }://#{ u.host }:#{ u.port}#{ redir }"
      end
    end

    # Sanity check: try to parse the result
    # and convert it back to a string
    u = URI.liberal_parse redir
    u.to_s
  end

  def apologize
    s = ''

    days = ( (@attempts.last.date - @attempts.first.date)/1.days ).floor + 1
    s << "  I tried to load this link #{ @attempts.size } times over a period of #{ days } days.\n"

    @attempts.each do |attempt|
      s << attempt.apologize
    end

    s
  end

  def trial_dates
    dates = @attempts.map { |attempt| attempt.date.informal_recent }
    comma_conjoin dates
  end

  def apologize_brief
    "I tried to load this link on #{trial_dates} but it never worked.  "
  end

  def is_new?
    @attempts.empty?
  end

  def has_enough_samples?
    @attempts.size >= MIN_LINK_FAILURES
  end

  def is_ready?
    is_new? or (Time.now - @attempts.last.date > LINK_TRIAL_PERIOD)
  end

  def observation ra
    @attempts << ra
  end

  def check!(http=nil)
    unless is_ready?
#      $log.puts "- link #{@url} is not ready to be tested again"
      return
    end

    uri = URI.liberal_parse @url
    $log.print "  "
    $log.print "(#{@attempts.size+1}) " unless @attempts.empty?
    $log.print "#{uri.request_uri} ... "

    custom_headers = {
      'User-Agent' => PUBLIC_USER_AGENT,
      'Referer'    => article2uri(@users.first || 'Hello world program')
    }

    skip_head = false
    unless is_new?
      last_try = @attempts.last.code
      unless (last_try =~ /^2\d\d$/) or (last_try =~ /^3\d\d$/)
        skip_head = true
      end
    end

    code, location, cookie = retrieve_head uri, http, custom_headers, :silent, skip_head

    case code
    when 'exception'
      observation(RetrievalAttempt.exc location)

    when 'other'
      observation(RetrievalAttempt.exc 'other')

    else
      observation(RetrievalAttempt.new code,location,cookie)
    end

    $log.puts @attempts.last
  end

end


