
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: thin abstraction over Net::HTTP for
## Description: unencrypted, non-authenticated sessions.
## Description: Provides keep-alive, user-agent, max-lag, gzip
## Description: encoding, retry on HTTP error, retry on API error,
## Description: captchas, and a simple method for scoping
## Description: and re-using HTTP connections.

# These methods all accept an optional http_in parameter,
# which means use this object for connection.  If it's
# nil, open/close a new connection for this method.

require 'net/http'
require 'net/https'
require 'uri'
require 'rexml/document'
require 'stringio'
require 'zlib'

require 'config'
require 'utils'
require 'multipart'

# These are the classes of errors for which we will try again.

# Retry on HTTP 5xx
# Also retry on TCP errors
#   (Net::HTTP reports these as exceptions; hence, abstraction inversion)
HTTP_RETRY_ERRORS = ['Connection reset by peer', 'end of file reached', 'Broken pipe']

# A larger set of errors for retry for idempotent requests (GET, HEAD; not POST)
HTTP_IDEMPOTENT_RETRY_ERRORS = HTTP_RETRY_ERRORS + ['wrong status line']

# A set of errors for which retry cannot help
HTTP_NO_RETRY_ERRORS = ['getaddrinfo: Name or service not known', 'Connection timed out - connect(2)', 'execution expired']

# MediaWikia API errors
API_RETRY_ERRORS = ['unknownerror', 'ratelimited', 'readonly', 'hookaborted']


# A wonderful method for scoped connections.
def reconnect(uri, http=nil)
  if connection_matches_uri? http, uri
    return yield http

  else
    begin
      # Create the HTTP object
      http = Net::HTTP.new uri.host, uri.port
      if uri.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end

      return yield http

    ensure
      # Make sure I finish the connection
      if http.started?
        http.finish
      end
    end
  end
end

def connection_matches_uri? http, uri
  return false if http == nil
  return false if http.address != uri.host

  if uri.scheme == 'http'
    if http.use_ssl?
      # Upgrade to SSL is okay.

    else
      # http + no ssl == okay
      # Make sure ports match
      return false if http.port != uri.port
    end

  elsif uri.scheme == 'https'
    if http.use_ssl?
      # https + ssl is okay
      # Make sure ports match
      return false if http.port != uri.port

    else
      # Downgrade from SSL NOT OKAY
      return false
    end
  end

  true
end

def escape_article_name name
  URI.escape( name.gsub(/\s/, '_') )
end

# API call to retrieve an article
def article2uri article
  "http://#{WIKI_LANGUAGE_CODE}.wikipedia.org/wiki/#{escape_article_name article}"
end

# get url for the API call to retrieve an
# article in raw format
def article2raw article
  uristr = article2uri(article) + "?action=raw"

  begin
    return URI.parse uristr
  rescue Exception => e
    $log.puts "Bad Article '#{article}': #{e}"
  end

  nil
end

# Link to an old revision of an article
def link_to_old_revision title, revision
  "http://#{WIKI_LANGUAGE_CODE}.wikipedia.org/w/index.php?title=#{escape_article_name title}&oldid=#{revision}"
end

# Link to an old revision's diff
def link_to_diff title, revision
  (link_to_old_revision title, revision) + '&diff=prev'
end


def retrieve_article(article, http_in=nil)
  retrieve_page( (article2raw article), http_in )
end

def retrieve_article_maxlag(article, http_in=nil)
  retrieve_page( (maxlag article2raw article), http_in )
end

def retrieve_revision(article, revid, http_in=nil)
  uristr = link_to_old_revision(article,revid) + '&action=raw'
  uri = nil

  begin
    uri = URI.parse uristr
  rescue Exception => e
    $log.puts "Bad Article '#{article}' revision #{revid}: #{e}"
    return [nil,nil]
  end

  retrieve_page uri, http_in
end

# Turn a URI into a URI with the max-lag option
def maxlag(uri)
  return nil if uri == nil

  ml = uri.dup
  ml.path = '/' if ml.path == ''

  if ml.query == nil or ml.query == ''
    ml.query = 'maxlag=5'

  else
    ml.query += '&maxlag=5'
  end

  ml
end

def retrieve_page_maxlag(uri,http_in=nil)
  retrieve_page( (maxlag uri), http_in )
end

def decode_response_body resp
  return nil if resp.body == nil

  if resp['content-encoding'] == 'gzip'
#    $log.puts '- decompress [gzip] encoding'
    StringIO.open(resp.body, 'r') do |sin|
      begin
        gzin = Zlib::GzipReader.new sin
        return gzin.read

      rescue Exception => e
        $log.puts "- broken gzip content? #{e}"

        if resp.body == nil
          $log.puts "  content is nil"
        else
          $log.puts "  content starts with '#{ resp.body[0..32] }'"
        end
        return nil

      ensure
        gzin.close unless gzin == nil
      end
    end
  end

  return resp.body
end

$maxlag_until = nil

def retrieve_page(uri, http_in=nil, extra_headers={}, silent=false)
  return [nil,nil] if uri==nil

  begin
    reconnect(uri, http_in) do |http|
      # Retry on HTTP error
      numAttempts = 0
      while numAttempts < MAX_HTTP_ATTEMPTS
        numAttempts += 1
        if numAttempts > 1
          http.finish
          sleep HTTP_RETRY_TIMEOUT
          $log.puts " - http attempt #{numAttempts}"
          http.start
        end
        try_again = false

        begin
          req = Net::HTTP::Get.new uri.request_uri
          req['User-Agent'] = HONEST_USER_AGENT
          req['Host'] = uri.host
          req['Accept-Encoding'] = 'gzip, identity'
          req['Connection'] = 'Keep-Alive'

          extra_headers.each do |k,v|
            req[k] = v
          end

          $log.print "GET '#{uri.pretty}': " unless silent
          http.start unless http.started?
          http.request req do |resp|

            # Did they send a max-lag?
            if uri.host.end_with? 'wikipedia.org'
              if resp['x-database-lag'] and resp['retry-after']
                lag = resp['x-database-lag'].to_i
                $log.puts "Max-Lag #{ lag }" unless silent
                retry_after = resp['retry-after'].to_i
                $log.puts "- go do something else for at least #{ retry_after }s." unless silent
                $maxlag_until = Time.now + [retry_after, EPSILON_WAIT].max
                return [nil,nil]
              else
                $maxlag_until = nil
              end
            end

            # Retry on 5xx errors (unless max-lag, see above)
            if resp.code =~ /^5\d\d$/
              $log.puts "#{resp.code}, HTTP retry" unless silent
              try_again = true

            elsif resp.code == '200'
              $log.puts "200" unless silent
              body = decode_response_body resp

              last_modification = resp['last-modified']
              if last_modification == nil
                return [body, nil]

              elsif last_modification =~ /[A-Za-z]+,\s+(\d+)\s+([A-Za-z]{3})\s+(\d{4})\s+(\d+):(\d+):(\d+)\s+GMT/
                revision = Time.utc( $3.to_i, $2, $1.to_i, $4.to_i, $5.to_i, $6.to_i )
                return [body, revision]

              else
                $log.puts "- Failed to parse revision time: #{ resp['last-modified'] }" unless silent
                return [body, nil]
              end

            else
              $log.puts "#{resp.code}, Failed." unless silent
            end
          end

        rescue Exception => e
          $log.puts "Exception while retrieving page: #{e}"
          err = e.to_s.sub(/:.*$/m, '')
          try_again = true if HTTP_IDEMPOTENT_RETRY_ERRORS.include? err
        end

        break unless try_again
      end
    end
  rescue Exception => e
    $log.puts "Exception during connection while retrieving page: #{e}"
  end

  return [nil,nil]
end

def retrieve_post(uri, args, http_in=nil, extra_headers={})
  begin
    reconnect(uri, http_in) do |http|

      # Retry on HTTP error
      numAttempts = 0
      while numAttempts < MAX_HTTP_ATTEMPTS
        numAttempts += 1
        if numAttempts > 1
          http.finish
          sleep HTTP_RETRY_TIMEOUT
          $log.puts " - http attempt #{numAttempts}"
          http.start
        end
        try_again = false

        begin
          req = Net::HTTP::Post.new uri.request_uri
          req['User-Agent'] = HONEST_USER_AGENT
          req['Host'] = uri.host
          req['Accept-Encoding'] = 'gzip, identity'
          req['Connection'] = 'Keep-Alive'

          extra_headers.each do |k,v|
            req[k] = v
          end


          req.set_post_data args

          $log.print "POST '#{uri.pretty}': "
          http.start unless http.started?
          http.request req do |resp|
            if resp.code =~ /^5\d\d$/
              $log.puts "#{resp.code}, HTTP retry"
              try_again = true

            else
              $log.puts "#{resp.code}"
              body = decode_response_body resp

              cookieline = resp['set-cookie']
              if cookieline
                asgnmt,junk = cookieline.split ';'
                return [resp.code, body, asgnmt]
              else
                return [resp.code, body]
              end
            end
          end

        rescue Exception => e
          $log.puts "- exception in retrieve_post: #{e}"
          err = e.to_s.sub(/:.*$/m, '')
          try_again = true if HTTP_RETRY_ERRORS.include? err
        end

        break unless try_again
      end
    end
  rescue Exception => e
    $log.puts "Exception during connect in retrieve_post: #{e}"
    return [e.to_s, nil]
  end

  return ['other', nil]
end

# The <meta> tag is blatant abstraction-inversion,
# and hence, this function is full of curses.
def parse_meta_tags body
  return [nil,nil] if body==nil

  location = nil
  cookie = false

  body.scan( /<\s*meta\s+([^>]*?)>/mi ) do |match|
    args = $1
    # - <meta http-equiv="location"
    if args =~ /http-equiv\s*=\s*['"]location['"]/mi
      if args =~ /content\s*=\s*['"]([^'"]*?)['"]/mi
        location = $1
      end

    # - <meta http-equiv="refresh"
    elsif args =~ /http-equiv\s*=\s*['"]refresh['"]/mi
      if args =~ /content\s*=\s*['"]\s*\d+\s*;\s*(url\s*=\s*)?([^'"]*?)['"]/mi
        location = $2.strip
      end

    # - <meta http-equiv="set-cookie"
    elsif args =~ /http-equiv\s*=\s*['"]set-cookie['"]/mi
      cookie = true
    end
  end

  [location,cookie]
end

# Given an HTTP response object,
# return: [code, location or nil, cookie boolean]
def head_parse_response uri, resp
  location = nil
  set_cookie = false

  redirect_type = ''
  cookie_type   = ''

  begin
    # Did it set a cookie?
    if resp['set-cookie']
      set_cookie = true
      cookie_type << 'Header-Set-Cookie, '
    end

    # Did it indicate a redirect?
    # - via the Location: header ?
    if resp['location']
      location = resp['location']
      redirect_type = 'Header-Location'

    # - via the Refresh: header ?
    elsif resp['refresh'] and resp['refresh'] =~ /^\s*\d+\s*;\s*url\s*=\s*(\S+)\s*/i
      location = $1.strip
      redirect_type = 'Header-Refresh'

    # - or via a <meta> tag?
    elsif resp['content-type'] =~ /html/i
      body = decode_response_body resp
      loc,cookie = parse_meta_tags body

      if loc
        location = loc
        redirect_type << 'Meta-Redirect, '
      end

      if cookie
        set_cookie = true
        cookie_type << 'Meta-Set-Cookie, '
      end
    end

  rescue Exception => e
    $log.puts "Exception while parsing HEAD response: #{e}"
  end

  return [resp.code, location, set_cookie]
end

# Return one of:
#   [http-status-code, location,         cookie]
#   ['exception',      exception-object, nil]
#   ['other',          nil,              nil]
def retrieve_head(uri, http_in=nil, extra_headers={}, silent=false)
  return ['other',nil,nil] if uri==nil

  begin
    reconnect(uri, http_in) do |http|

      # Try HTTP HEAD once, since it might be fast.
      begin
        old_connect_timeout = http.open_timeout
        if OVERRIDE_HTTP_CONNECT_TIMEOUT
          http.open_timeout = OVERRIDE_HTTP_CONNECT_TIMEOUT
        end
        old_read_timeout = http.read_timeout
        if OVERRIDE_HTTP_READ_TIMEOUT
          http.read_timeout = OVERRIDE_HTTP_READ_TIMEOUT
        end



        req = Net::HTTP::Head.new uri.request_uri
        req['User-Agent'] = HONEST_USER_AGENT
        req['Host'] = uri.host
        req['Connection'] = 'Keep-Alive'

        extra_headers.each do |k,v|
          req[k] = v
        end

        $log.print "HEAD '#{uri.pretty}': " unless silent
        http.start unless http.started?
        http.request req do |resp|
          if resp.code !~ /^4\d\d$/ and resp.code !~ /^5\d\d$/
            $log.puts resp.code unless silent
            return head_parse_response uri, resp
          end

          $log.print "(#{resp.code}) " unless silent
        end
      rescue Exception => e
        $log.puts "Exception while retrieving head: #{e}"
        if HTTP_NO_RETRY_ERRORS.include? e.to_s
          return ['exception', e, nil]
        end

        try_again = true

      ensure
        http.read_timeout = old_read_timeout
        http.open_timeout = old_connect_timeout
      end

      # Retry on HTTP error
      numAttempts = 1
      while numAttempts < MAX_HTTP_ATTEMPTS
        numAttempts += 1
        if numAttempts > 1
          http.finish if http.started?
          sleep HTTP_RETRY_TIMEOUT
          $log.puts " - http attempt #{numAttempts}"
          http.start
        end
        try_again = false

        begin
          # Retry with a GET on 4xx and 5xx errors.
          # HTTP 405 means we the server doesn't support HEAD for this URL
          # A server /should/ return 405 whenever HEAD doesn't match GET,
          # but many don't.  Thus, we don't trust 4xx/5xx on HEAD.

          # Try again with HTTP GET
          req = Net::HTTP::Get.new uri.request_uri
          req['User-Agent'] = HONEST_USER_AGENT
          req['Host'] = uri.host
          req['Connection'] = 'Keep-Alive'
          req['Accept-Encoding'] = 'gzip, identity'

          extra_headers.each do |k,v|
            req[k] = v
          end

          http.request req do |resp|
            $log.puts resp.code unless silent
            return head_parse_response uri, resp
          end

        rescue Exception => e
          $log.puts "Exception while retrieving head: #{e}"
          err = e.to_s.sub(/:.*$/m, '')
          unless HTTP_IDEMPOTENT_RETRY_ERRORS.include? err
            return ['exception', e, nil]
          end

          try_again = true
        end

        break unless try_again
      end
    end
  rescue Exception => e
    $log.puts "Exception during connect while retrieving head: #{e}"
    return ['exception', e, nil]
  end

  return ['other',nil,nil]
end

# Perform an API request.
# If the request succeeds at the HTTP layer,
# yield the parsed XML document.  The block should return
# if successful.  If the block falls-through, then
# this routine will either retry on some errors, or
# fail.
def api_request(uri, args, http_in=nil, extra_headers={})
  args['format'] ||= 'xml'

  numAttempts = 0
  while numAttempts < MAX_API_ATTEMPTS
    numAttempts += 1
    if numAttempts > 1
      $log.puts "- ...api attempt #{numAttempts}"
    end

    code,body = retrieve_post uri, args, http_in, extra_headers
    if code != '200'
      $log.puts "- http code #{code}"
      return ["failure http code #{code}",nil]
    end

    xml = REXML::Document.new body

    # If successfuly, this should return.
    yield xml

    # It failed because of a captcha?
    id,answer = captcha uri, xml, http_in
    if answer
      args['captchaid'] = id
      args['captchaword'] = answer
      next # retry, no timeout

    else
      # I don't think this can be re-used
      # if a captcha-challenge is followed
      # by a rate limit.
      args.delete 'captchaid'
      args.delete 'captchaword'
    end

    # Is there an /api/error tag?
    again = false
    xml.elements.each('/api/error') do |elt|
      code = (REXML::Text.unnormalize elt.attribute('code').to_s ).downcase
      info =  REXML::Text.unnormalize elt.attribute('info').to_s

      unless API_RETRY_ERRORS.include? code
        $log.puts "- Non-retry error: #{code}\n#{elt}"
        return ["failure api error #{code}: #{info}; no retry",nil]
      end

      $log.puts "- retry code: #{code}"
      again = true
    end

    if again
      sleep API_RETRY_TIMEOUT
      next
    end

    $log.puts body
    return ['failure other', body]
  end

  return ['failure max tries', nil]
end

def retrieve_contributions(user, limit=10, http_in=nil)
  begin
    args = {
      "action"    => "query",
      "list"      => "usercontribs",
      "ucuser"    => user,
      "uclimit"   => limit.to_s,
      "ucdir"     => "older",
      "ucprop"    => "title|ids|timestamp|comment"
    }

    api_request INSECURE_API_URL,args,http_in do |xml|
      result = []
      xml.elements.each('/api/query/usercontribs/item') do |contrib|
        title = REXML::Text.unnormalize contrib.attribute('title').to_s
        revid = contrib.attribute('revid').to_s.to_i
        comment = REXML::Text.unnormalize contrib.attribute('comment').to_s
        timestamp = REXML::Text.unnormalize contrib.attribute('timestamp').to_s
        time = nil
        if timestamp =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z/
          time = Time.utc( $1.to_i, $2.to_i, $3.to_i,  $4.to_i, $5.to_i, $6.to_i )
        else
          $log.puts "retrieve_contributions: Can't parse timestamp #{timestamp}"
        end

        result << [title, revid, time, comment]
      end

      $log.puts "- found #{result.size} contributions."
      return result
    end

  rescue Exception => e
    $log.puts "- exception in retrieve_contributions: #{e} #{e.backtrace}"
  end
  []
end

def captcha uri, xml, http_in
  return [nil,nil] if CAPTCHA_USER_TIMEOUT < 1

  xml.elements.each('//captcha') do |elt|
    id  = elt.attribute('id')
    return [nil,nil] unless id

    path = elt.attribute('url')
    return [nil,nil] unless path

    path = REXML::Text.unnormalize path.to_s
    imguri = URI.parse(uri.scheme + '://' + uri.host + ':' + uri.port.to_s + path)

    image,date = retrieve_page imguri, http_in
    return [nil,nil] unless image

    tmpdir = ENV['TMPDIR'] || '/tmp'
    imagefile = "#{tmpdir}/captcha.png"

    File.atomic_create(imagefile) do |fout|
      fout.puts image
    end

    # Show the image.
    image_viewer = fork {
      $stdout.close
      $stdout = File.open '/dev/null', 'a'
      $stderr.close
      $stderr = File.open '/dev/null', 'a'
      exec IMAGE_VIEWER_APP, imagefile
    }

    # Read the response from the user.
    # Fail if they don't respond within the timeout.
    $log.flush
    $stdout.print "Captcha: "
    $stdout.flush
    if IO.select [$stdin],nil,nil,CAPTCHA_USER_TIMEOUT
      answer = $stdin.gets.strip
    else
      $stdout.puts "(I guess nobody's home)"
      $stdout.flush
      answer = nil
    end

    # Kill the image viewer if its still around
    Process.kill "KILL", image_viewer
    Process.waitpid image_viewer

    # Remove the image file
    File.delete imagefile

    return [id.to_s,answer]
  end

  return [nil,nil]
end


