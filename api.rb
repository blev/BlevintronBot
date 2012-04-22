## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: secure, authenticated editing sessions.

require 'uri'
require 'net/http'
require 'net/https'
require 'rexml/document'
require 'md5'

require 'config'
require 'retrieve'
require 'multipart'

class Session
  def initialize
    @connection = nil
    login_failed!
  end

  def login(u,p)
    return if logged_in?

    begin
      $log.puts "Login..."

      uri = SECURE_API_URL
      @connection = Net::HTTP.new( uri.host, uri.port )
      if uri.scheme == 'https'
        @connection.use_ssl = true
        @connection.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end

      # Ruby's Net::HTTP will only honor Connection: Keep-Alive
      # If you .start the connection before you issue a .request.
      # Why!?!?!
      @connection.start

      req = Net::HTTP::Post.new uri.request_uri
      req['User-Agent'] = HONEST_USER_AGENT
      req['Accept-Encoding'] = 'gzip'
      req['Connection'] = 'Keep-Alive'

      req.set_post_data({
        'action' => 'login',
        'lgname' => u,
        'lgpassword' => p,
        'format' => 'xml'
      })

      need_token = false
      @connection.request req do |resp|
        if resp.code != '200'
          login_failed!
          $log.puts "Login failed (1): status code #{ resp.code }"
          return false
        end

        body = decode_response_body resp
        xml = REXML::Document.new body
        xml.elements.each('/api/login') do |elt|
          result = elt.attribute('result').to_s

          if result == 'Success'
            parse_login_elt elt
            @logged_in = true
            $log.puts "... logged in"
            return true

          elsif result == 'NeedToken'
            parse_login_elt elt
            need_token = elt.attribute('token').to_s

          else
            login_failed!
            $log.puts "Failed login (11): result=#{ result }"
            return false
          end
        end
      end

      if need_token
        req = Net::HTTP::Post.new uri.request_uri
        req['User-Agent'] = HONEST_USER_AGENT
        req['Accept-Encoding'] = 'gzip'
        req['Cookie'] = cookie
        req['Connection'] = 'Keep-Alive'

        req.set_post_data({
          'action' => 'login',
          'lgname' => u,
          'lgpassword' => p,
          'format' => 'xml',
          'lgtoken' => need_token
        })

        @connection.request req do |resp|
          if resp.code != '200'
            login_failed!
            $log.puts "Login failed (2): status code #{ resp.code }"
            return false
          end

          body = decode_response_body resp
          xml = REXML::Document.new body
          xml.elements.each('/api/login') do |elt|
            result = elt.attribute('result').to_s

            if result == 'Success'
              parse_login_elt elt
              @logged_in = true
              $log.puts "... logged in"
              return true

            else
              login_failed!
              $log.puts "Failed login (21): result=#{ result }"
              return false
            end
          end
        end
      end

    rescue Exception => e
      login_failed!
      $log.puts "Exception during login: #{e}"
      return false
    end

  end

  def logout
    return unless logged_in?

    unless @connection.active?
      $log.puts "  XXX.5 Why did connection close?"
    end

    begin
      $log.puts "Logout..."
      uri = SECURE_API_URL
      req = Net::HTTP::Post.new uri.request_uri
      req['User-Agent'] = HONEST_USER_AGENT
      req['Accept-Encoding'] = 'gzip'
      req['Cookie'] = cookie

      req.set_post_data 'action' => 'logout'

      @connection.request req do |resp|
        $log.puts "... logout: #{resp.code}"
      end

    ensure
      login_failed!
    end
  end

  # Replace the content of article with newText
  #   article - article title
  #   oldRevisionTime - timestamp of last revision
  #   message - edit summary message
  #   newText - new page contents
  # Returns:
  #   ['Success', newRevisionIdInteger] on success
  #   ['Message', extra] on failure
  def replace(article, oldRevisionTime, message, newText)
    throw 'must log in' unless logged_in?

    if LIMIT_EDIT_ARTICLES
      unless LIMIT_EDIT_ARTICLES.include? article
        $log.puts "(LIMIT_EDIT_ARTICLES) I refuse to edit #{article}"
        return ['Refused', 'LIMIT_EDIT_ARTICLES']
      end
    end

    begin
      md5 = MD5.new
      md5 << newText

      args = {
        'action' => 'edit',
        'title' => article,
        'text' => newText,
        'summary' => "BOT: #{message}.  [[User_talk:#{BOT_USERNAME} | Please report any problems]].", # to [[User_talk:#{OPERATOR_USERNAME}|#{OPERATOR_USERNAME}]].",
        'bot' => 'true',
        'md5' => md5.hexdigest,
        'assert' => 'user',
        'token' => editToken
      }

      if oldRevisionTime != nil
        time = oldRevisionTime.mediawiki
        args['basetimestamp'] = time
        args['starttimestamp'] = time
      end

      api_request SECURE_API_URL, args, @connection, {'Cookie'=>cookie} do |xml|
        xml.elements.each('/api/edit') do |elt|
          if elt.attribute('result').to_s == 'Success'
            return ['Success', elt.attribute('newrevid').to_s.to_i]
          end
        end
      end

    rescue Exception => e
      puts e
      puts(e.backtrace.join "\n")
      return ['exception', e]
    end

    return ['failure other', nil]
  end

  # Append this message to 'user's User_talk: page.
  # Automatically adds a signature at the end.
  # Returns:
  #   ['Success', newRevisionIdInteger] on success
  #   ['Message', extra] on failure
  def send_message_to(user, subject, text)
    user_talk = "User_talk:#{user}"

    refused = filter_message user
    return ['Refused', refused] if refused

    # We passed the filters, ergo
    # We are 'allowed' to send the message.

    # Append opt-out and signature to the message body.
    msg = ''
    msg << text
    msg << "\n{{subst:User:#{BOT_USERNAME}/Bot/Madlibs/2/OptOut | bot=#{BOT_USERNAME} | operator=#{OPERATOR_USERNAME} | recipient=#{user} }}\n"
    msg << "~~~~"

    append_section(user_talk, subject, msg)
  end

  def logged_in?
    @logged_in
  end

private
  def cookie
    str = ''
    @cookies.each do |name,value|
      next if value == nil

      str << '; ' unless str == ''
      str << "#{name}=#{value}"
    end
    str
  end

  def login_failed!
    if @connection and @connection.started?
      @connection.finish
    end

    @logged_in = false
    @cookies = {}
    @editToken = nil
    @connection = nil
  end

  def parse_login_elt elt
    prefix = REXML::Text.unnormalize elt.attribute('cookieprefix').to_s
    @cookies[ "#{prefix}_session" ] = REXML::Text.unnormalize( ( elt.attribute('sessionid')  || '' ).to_s )
    @cookies[ "#{prefix}UserName" ] = REXML::Text.unnormalize( ( elt.attribute('lgusername') || '' ).to_s )
    @cookies[ "#{prefix}UserID" ]   = REXML::Text.unnormalize( ( elt.attribute('lguserid')   || '' ).to_s )
    @cookies[ "#{prefix}Token" ]    = REXML::Text.unnormalize( ( elt.attribute('lgtoken')    || '' ).to_s )
  end

  def editToken
    unless @editToken
      result,token = fetchEditToken
      if result == 'Success'
        @editToken = token
      end
    end

    return @editToken
  end

  def fetchEditToken
    throw 'must log in' unless logged_in?

    begin
      args = {
        'action' => 'query',
        'prop' => 'info',
        'intoken' => 'edit',
        'titles' => 'Main Page'
      }

      api_request SECURE_API_URL,args,@connection, {'Cookie'=>cookie} do |xml|
        xml.elements.each('/api/query/pages/page')  do |elt|
          return ['Success', REXML::Text.unnormalize( elt.attribute('edittoken').to_s )]
        end
      end

    rescue Exception => e
      $log.puts "Exception while getting edit token: #{e}"
    end

    return ['failure', nil]
  end

  # Adds a new section to the tail of the given page.
  # Returns:
  #   ['Success', newRevisionIdInteger] on success
  #   ['Message', extra] on failure
  def append_section(article, sectionTitle, newText)
    throw 'must log in' unless logged_in?

    begin
      md5 = MD5.new
      md5 << newText

      args = {
        'action' => 'edit',
        'title' => article,
        'section' => 'new',
        'sectiontitle' => sectionTitle,
        'text' => newText,
        'summary' => "BOT: #{ sectionTitle }",
        'bot' => 'true',
        'md5' => md5.hexdigest,
        'assert' => 'user',
        'token' => editToken
      }

      api_request SECURE_API_URL,args,@connection, {'Cookie'=>cookie} do |xml|
        xml.elements.each('/api/edit') do |elt|
          if elt.attribute('result').to_s == 'Success'
            return ['Success', elt.attribute('newrevid').to_s.to_i]
          end
        end
      end

    rescue Exception => e
      return ['exception', e]
    end

    return ['failure other', nil]
  end

  def filter_message user
    # The bot's operator is NOT allowed to block our messages
    return false if user == OPERATOR_USERNAME

    # First, reject certain classes of usertalk messages
    if LIMIT_CONTACT_USERTALK
      unless LIMIT_CONTACT_USERTALK.include? user
        $log.puts "(LIMIT_CONTACT_USERTALK) I refuse to contact #{user}"
        return 'LIMIT_CONTACT_USERTALK'
      end
    end

    if NEVER_CONTACT_IP_USERS
      if user =~ /^\d+\.\d+\.\d+\.\d+$/
        $log.puts "(NEVER_CONTACT_IP_USERS) I refuse to contact #{user}"
        return 'NEVER_CONTACT_IP_USERS'
      end
    end

    # Has the user excluded talk messages?
    # - via their User_talk: page
    user_talk = "User_talk:#{user}"
    page,time = retrieve_article user_talk, @connection
    if page and wiki_forbids_bots? page
      $log.puts "User #{user} has opted-out of messages via User_talk: {{bots}}."
      return 'User_talk: {{bots}}'
    end

    # Don't mess with redirects.
    if page and wiki_redirect? page
      $log.puts "(Wiki Redirect) TODO follow redirect"
      return 'Wiki Redirect'
    end

    # Has the user excluded talk messages?
    # - or via their User: page
    page,time = retrieve_article "User:#{user}", @connection
    if page and wiki_forbids_bots? page
      $log.puts "User #{user} has opted-out of messages via User: {{bots}}."
      return 'User: {{bots}}'
    end

    # Never contact Bots
    if page and wiki_is_bot_page? page
      $log.puts "User #{user} is a bot"
      return 'Bot User'
    end

    # Determine number of contributions this user has
    # made over the last N months.
    if USER_INACTIVITY_THRESHOLD
      last_contrib = retrieve_contributions user, 1, @connection
      if last_contrib.empty? or
         last_contrib.first[2] == nil or # timestamp nil?
         (Time.now - last_contrib.first[2]) >= USER_INACTIVITY_THRESHOLD

        $log.puts "(USER_INACTIVITY_THRESHOLD) User #{user} is inactive."
        return 'USER_INACTIVITY_THRESHOLD'
      end
    end

    # All other cases are unfiltered.
    false
  end
end

class Api
  def self.session(username, password)
    session = Session.new

    begin
      return false unless session.login(username,password)

      yield session

    ensure
      session.logout
    end
  end
end

