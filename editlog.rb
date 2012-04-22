
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: maintain a record of which edits I have done in the past.

require 'uri'
require 'net/http'
require 'rexml/document'

require 'utils'
require 'config'
require 'api'
require 'retrieve'

class ExperimentCase
  attr_reader :do_edit, :do_solicit

  def initialize(edit=true, solicit=true)
    @do_edit = edit
    @do_solicit = solicit
  end

  def self.random
    case rand(3)
    when 0
      # No edit, no solicitation
      return ExperimentCase.new(false,false)
    when 1
      # Edit, but no solicitation
      return ExperimentCase.new(true,false)
#    when 2
#      # Solicit, but make no edits
#      return ExperimentCase.new(false,true)
    else
      # Edit and solicit
      return ExperimentCase.new(true,true)
    end
  end

  def self.select(force=nil)
    if force
      return force

    elsif EFFECTIVENESS_EXPERIMENT
      return ExperimentCase.random

    else
      return ExperimentCase.new
    end
  end

  def to_s
    s = ''
    if @do_edit
      s << "+E"
    else
      s << "-E"
    end

    if @do_solicit
      s << "+S"
    else
      s << "-S"
    end
    s
  end

  # For case (-E-S) we do not need to login at all.
  def no_connect?
    (not @do_edit) and (not @do_solicit)
  end

  def ==(other)
    (self.do_edit == other.do_edit) and (self.do_solicit == other.do_solicit)
  end
end


# Holds a record of a single change I have made to wikipedia.
class EditLogEntry
  attr_reader :title, :old_rev_time
  attr_reader :edit_time, :new_revision_id
  attr_reader :experiment_case

  attr_accessor :message, :bad_links

  attr_accessor :nArchived, :nBroken, :nUnfixed

  attr_accessor :valid_data_point
  attr_accessor :new_revision_id
  attr_accessor :solicitations

  def initialize(tit, oldrev, force_case=nil)
    @title = tit
    @message = nil
    @old_rev_time = oldrev
    @bad_links = []
    @edit_time = Time.now

    # Counts of occurrences of dead links in the
    # article, and how we fixed each.
    nArchived = 0
    nBroken = 0
    nUnfixed = 0

    # Experiment statistics--which bin?
    @valid_data_point = true
    @experiment_case = ExperimentCase.select(force_case)

    # Only set if the edit was successful
    @new_revision_id = nil

    # Only set if the solicitations were sent.
    @solicitations = []
  end

  def had_time_for_review?
    Time.now - @edit_time >= CHECK_FOR_REVERTS_TIMEFRAME
  end

  def time
    @new_revision_id || @old_rev_time
  end

  # -------- interesting statistics

  # If this revision has been reverted, return [true, username, revisionid, summary]
  # Otherwise, [false, x, x, x]
  def has_been_reverted? history
    return false unless @experiment_case.do_edit

    history.each do |revid,timestamp,author,summary|
      revert,revid,user = looks_like_revert? summary

      if revert and revid == @new_revision_id
        # Perfect match
        return [true, author, revid, summary]

      elsif revert and user and user.canon == BOT_USERNAME.canon
        # Fuzzy match
        return [true, author, revid, summary]
      end
    end

    return [false, nil, nil, nil]
  end

  # What fraction of the links have been fixed, either
  # by removal, replacement, or adding an archiveurl= alternative.
  def measure_improvement latest_revision
    nTotal = @bad_links.size
    return nil if nTotal < 1

    # Remove all of /our/ broken link tags from the latest copy.
    redacted = latest_revision.dup
    redacted.each_template do |tag|
      next unless tag.is_dead?
      next unless tag['bot']
      next unless tag['bot'].downcase.start_with? BOT_NAME.downcase

      tag.redact_from! redacted
    end

    # This excludes links that are marked dead
    # or which have an archiveurl= alternative.
    latest_urls = scrape_article redacted
    nRemaining = @bad_links.count {|bad_link| latest_urls.include? bad_link.url}

    imprvt = (nTotal - nRemaining).to_f / nTotal
    $log.puts " -- Improvement: #{imprvt} of links improved"
    imprvt
  end

  def measure_participation history, bot_users={}, http_in=nil
    numAuthors = @solicitations.size

    # Count how many of the contributions are
    # from non-bot accounts
    numHumanContribs = 0
    if history.size > 0
      reconnect(INSECURE_API_URL,http_in) do |http|
        history.each do |revid,timestamp,author,summary|
          unless bot_users.has_key? author
            # Look up this user; decide if they are a bot.
            page,date = retrieve_article "User:#{author}", http
            bot_users[author] = (page and wiki_is_bot_page? page)
          end

          numHumanContribs += 1 unless bot_users[author]
        end
      end
    end

    $log.puts " -- Participation: #{numHumanContribs} total human edits"
    return [numHumanContribs,nil,nil] if numAuthors == 0

    # Count contributions among solicited users
    participation_total = 0
    numContributingAuthors = 0
    @solicitations.each do |sol_user, sol_revid|
      n = history.count {|hist_id,hist_date,hist_author,hist_cmt| hist_author == sol_user}

      participation_total += n
      numContributingAuthors += 1 if n > 0
    end

    part_per_sol = participation_total.to_f / numAuthors
    $log.puts " -- Participation: #{participation_total} edits / #{numAuthors} solicited authors"

    frac_sol = numContributingAuthors.to_f / numAuthors
    $log.puts " -- Participation: #{numContributingAuthors} / #{numAuthors} solicited authors have contributed"

    [numHumanContribs, part_per_sol, frac_sol]
  end

  def measure_blocked_userpages http_in=nil
    return nil unless @experiment_case.do_solicit
    numAuthors = @solicitations.size
    return nil if numAuthors == 0

    reconnect(INSECURE_API_URL, http_in) do |http|
      numBlocks = 0

      @solicitations.each do |sol_user, sol_id|

        body, date = retrieve_article "User:#{sol_user}", http
        if body and wiki_forbids_bots? body
          numBlocks += 1
          next
        end

        body, date = retrieve_article "User_talk:#{sol_user}", http
        if body and wiki_forbids_bots? body
          numBlocks += 1
          next
        end
      end

      $log.puts " -- Annoyance: blocked from #{numBlocks} user pages / #{numAuthors} solicited users"
      numBlocks.to_f/numAuthors
    end
  end

end




