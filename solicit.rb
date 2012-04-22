
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: compose solicitation letters

require 'pp'

require 'config'
require 'link'
require 'nobots'
require 'throttling'
require 'markup'
require 'rexml/document'
require 'yaml'
require 'utils'
require 'archive'
require 'api'
require 'reverts'
require 'retrieve'
require 'history'


class DB

  # Returns an array of [user,subject,message]
  def compose_solicitations name, broken_links, introductions, replacements, exp_case
    solicitations = []

    # Invert the introduction map
    # From:  {pattern => [rev,time,user,comment]}
    # To:    {user => {rev => [ time, links ] }}
    by_user = {}
    broken_links.each do |link|
      url = link.url
      next unless introductions.has_key? url
      rev,time,user,comment = introductions[ url ]

      by_user[user] ||= {}
      by_user[user][rev] ||= [time, []]

      by_user[user][rev][1].push link
    end

    # Write a note to the users who introduced now-broken links
    by_user.each_key do |intro_user|
      # How many links are we talking about:
      # Singular or plural nouns?
      my_intros = by_user[intro_user]
      nLinks = 0 
      my_intros.each_key do |intro_rev|
        intro_time,intro_links = my_intros[intro_rev]
        nLinks += intro_links.size
      end

      # ---- subject line
      # TODO: transclude a subject line.
      # Wikipedia doesn't seem to like it...
      subject = ''
      if nLinks == 1
        subject << "Dead link "
      else
        subject << "Dead links "
      end
      subject << "in article '[[#{name}]]'"

      # ---- message body
      msg = ''
      msg << "{{subst:User:#{BOT_USERNAME}/Bot/Madlibs/2/Hello | article=#{name} | num=#{nLinks} }}"

      my_intros.keys.sort.each do |intro_rev|
        intro_time, intro_links = my_intros[intro_rev]

        msg << "{{subst:User:#{BOT_USERNAME}/Bot/Madlibs/2/Revision | article=#{name} | revid=#{intro_rev} | revdate=#{intro_time.informal_old} | num=#{intro_links.size} }}"

        intro_links.each do |intro_link|

          archive_date,archive_url = replacements[intro_link.url]

          msg << "{{subst:User:#{BOT_USERNAME}/Bot/Madlibs/2/Link | article=#{name} | revid=#{intro_rev} | revdate=#{intro_time.informal_old} | url=#{intro_link.url} | checkdates=#{intro_link.trial_dates} | archive=#{archive_url} }}"

        end

        msg << "{{subst:User:#{BOT_USERNAME}/Bot/Madlibs/2/EndRevision | article=#{name} | revid=#{intro_rev} | revdate=#{intro_time.informal_old} | num=#{intro_links.size} }}"
      end

      msg << "{{subst:User:#{BOT_USERNAME}/Bot/Madlibs/2/Goodbye | article=#{name} | num=#{nLinks} | numArchived=x }}"

      solicitations << [intro_user, subject, msg]
    end

    solicitations
  end

private

  def throttle_solicitation? user
    if @solicits_per_user.has_key? user
      last = @solicits_per_user[user]
      return true if (Time.now - last) < MIN_SOLICIT_PERIOD_PER_USER

      # That was a long time ago.
      stats_dirty!
      @solicits_per_user.delete user
    end
    false
  end

  # Keep track of how many solicitations I sent to each user
  # over a calendar day.
  def sent_a_solicitation! user
    stats_dirty!
    @numSolicitations += 1
    @solicits_per_user[user] = Time.now
  end


end


