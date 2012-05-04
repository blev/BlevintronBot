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
  attr_writer :connection

  def initialize(u,p)
    @username = u
    @password = p
    @connection = nil
    login_failed!
  end

  def login
    logout if stale?
    return true if logged_in?

    begin
      $log.puts "Login..."

      result,token = try_login
      if result == 'NeedToken'
        result,token = try_login token
      end

      @login_time = Time.now
      return (result == 'Success')

    rescue Exception => e
      $log.puts "Exception during login: #{e}"
    end

    login_failed!
    return false
  end


  def logout
    return unless logged_in?

    begin
      $log.puts "Logout..."
      api_request SECURE_API_URL, {'action'=>'logout'}, @connection, {'Cookie'=>cookie} do |xml|
        $log.puts "... logout."
        return
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
    return ['Failure', 'cannot login'] unless login

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
        'summary' => "BOT: #{message}.  [[User_talk:#{BOT_USERNAME} | Please report any problems]].",
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
      $log.puts e
      $log.puts(e.backtrace.join "\n")
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

  def logged_out?
    not logged_in?
  end

private
  def stale?
    return false unless @login_time
    (Time.now - @login_time) > LOGIN_TTL
  end

  def try_login(token=nil)
    args = {
      'action' => 'login',
      'lgname' => @username,
      'lgpassword' => @password
    }
    args['lgtoken'] = token if token

    api_request SECURE_API_URL,args,@connection,{'Cookie'=>cookie} do |xml|
      xml.elements.each('/api/login') do |elt|
        result = elt.attribute('result').to_s

        case result
        when 'Success'
          parse_login_elt elt
          @logged_in = true
          $log.puts "... logged in"
          return ['Success',nil]

        when 'NeedToken'
          parse_login_elt elt
          return ['NeedToken', elt.attribute('token').to_s]

        else
          $log.puts "Failed login (11): result=#{ result }"
        end
      end

      login_failed!
      return ['Failure',nil]
    end

    login_failed!
    return ['Failure',nil]
  end

  def login_failed!
    @logged_in = false
    @cookies = {}
    @editToken = nil
    @login_time = nil
  end

  def parse_login_elt elt
    prefix = REXML::Text.unnormalize elt.attribute('cookieprefix').to_s
    @cookies[ "#{prefix}_session" ] = REXML::Text.unnormalize( ( elt.attribute('sessionid')  || '' ).to_s )
    @cookies[ "#{prefix}UserName" ] = REXML::Text.unnormalize( ( elt.attribute('lgusername') || '' ).to_s )
    @cookies[ "#{prefix}UserID" ]   = REXML::Text.unnormalize( ( elt.attribute('lguserid')   || '' ).to_s )
    @cookies[ "#{prefix}Token" ]    = REXML::Text.unnormalize( ( elt.attribute('lgtoken')    || '' ).to_s )
  end

  def cookie
    str = ''
    @cookies.each do |name,value|
      next if value == nil or value == ''

      str << '; ' unless str == ''
      str << "#{name}=#{value}"
    end
    str
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
    return ['Failure', 'cannot login'] unless login

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
    return ['Failure', 'cannot login'] unless login

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

    # All other cases are unfiltered.
    false
  end
end

# This is basically an authentication pool
class Api
  @@active_sessions = {}

  def self.session(username, password, http_in=nil)
    unless @@active_sessions.has_key? username
      @@active_sessions[username] = Session.new(username,password)
    end

    s = @@active_sessions[username]
    reconnect(SECURE_API_URL,http_in) do |http|
      begin
        s.connection = http
        return yield s

      ensure
        s.connection = nil
      end
    end
  end
end

