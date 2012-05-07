## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: code for editing articles in response to known problems.

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
require 'solicit'
require 'editlog'
require 'fix'

class Editor

  def perform_edits!
    return if $cancel

    unless should_start_edit?
      wait
      return
    end

    best_article = select_article_to_edit
    edit_one_article! best_article

    manage_bad_links
  end

  def edit_one_article! name
    start_time = Time.now

    $log.puts
    $log.puts
    $log.puts "Edit #{ Time.now }"
    $log.puts "  Article '#{name}' has problem links"

    # debugging limit.
    if LIMIT_EDIT_ARTICLES
      unless LIMIT_EDIT_ARTICLES.include? name
        $log.puts "  (LIMIT_EDIT_ARTICLES) I won't edit this"
        return nil
      end
    end

    # Re-fetch the page as it exists now
    body = ''
    revision = nil
    body, revision = retrieve_article_maxlag name

    # FAIL ON MAX LAG HERE
    return :maxlag if body == nil

    # sanity
    body.freeze

    if wiki_forbids_bots? body
      # The article did  not exclude our initially scraping ...
      # We assume it is temporary and try later. We don't remove
      # the record from @bad.
      $log.puts "  This article excludes bots."
      return nil

    elsif wiki_in_use? body
      # Necessarily temporary; try again later.
      $log.puts "  This article is in use."
      return nil
    end

    new_body,message,archived_links,nArchived,broken_links,nBroken,remaining_links,nUnfixed,introductions,replacements = fix_links name,body
    return if new_body == nil
    # Did we make any changes?
    if body == new_body
      $log.puts "  No edits"
      return nil
    end

    return if broken_links == nil
    return if introductions == nil or introductions.empty?

    # All links that contribute to this edit.
    contributing_bad_links = (archived_links + broken_links).uniq

    # These are the users we will send notifications to.
    solicited_users = broken_links.map do |link|
      if introductions.has_key? link.url
        introductions[ link.url ][2]
      else
        nil
      end
    end
    solicited_users.compact!
    solicited_users.uniq!

    # For the sake of the experiment, we want the four
    # cases to be disjoint.  So, we are going to look
    # over the previous edits to see if this article
    # and the people involved have not already been
    # placed into one of the cases.
    #
    # If we cannot assign the article/users to an
    # experiment case that maintains the disjointedness
    # property, we will postpone this edit.
    force_case = nil
    if EFFECTIVENESS_EXPERIMENT
      # Has the article been placed into an experiment case already?
      if @previous_edits.has_key? name
        # This article is not disjoint from the rest of the experiment.
        # Try to force it into a case to maintain disjoint cases.
        @previous_edits[name].each do |past_edit|
          if nil == force_case
            # Not yet forced
            force_case = past_edit.experiment_case
            $log.puts "  This article was previously in case #{force_case}"

          elsif force_case != past_edit.experiment_case
            # Conflict; no case is possible.
            # postpone the edit (we have enough that we can choose another)
            $log.puts " Article was also in #{past_edit.experiment_case}"
            $log.puts "POSTPONE edit to article '#{name}'"
            return nil
          end
        end
      end

      # Have any of the users been placed
      # into a case already?
      @previous_edits.each do |art,revs|
        revs.each do |past_edit|
          past_edit.solicitations.each do |sol_user,sol_revid|
            if solicited_users.include? sol_user
              # This user is already in the experiment.
              # Try to force this edit into a case so that
              # the cases remain disjoint.
              if nil == force_case
                # Not yet forced
                force_case = past_edit.experiment_case
                $log.puts "  User #{sol_user} was previously in case #{force_case}"

              elsif force_case != past_edit.experiment_case
                # Conflict; no case is possible.
                # postpone the edit (we have enough that we can choose another)
                $log.puts "  User #{sol_user} was previously in case #{past_edit.experiment_case}"
                $log.puts "POSTPONE edit to article '#{name}'"
                return
              end
            end
          end
        end
      end
    end

    # Create a record of this edit; populate it
    this_edit = EditLogEntry.new name,revision,force_case
    this_edit.message = message
    this_edit.bad_links = contributing_bad_links
    this_edit.nArchived = nArchived
    this_edit.nBroken = nBroken
    this_edit.nUnfixed = nUnfixed

    # If any of these letters would be refused,
    # then instead postpone this article and edit
    # a different one.
    if this_edit.experiment_case.do_solicit
      solicited_users.each do |sol_user|
        if throttle_solicitation? sol_user
          # postpone the edit (we have enough that we can choose another)
          $log.puts "  User #{sol_user} has already received a solicitation recently."
          $log.puts "POSTPONE edit to article '#{name}'"
          return nil
        end
      end
    end

    $log.puts "'#{name}': '#{message}'"

    # Compose some letters, asking other contributors
    # for help with these broken links.
    letters = compose_solicitations(
      name,
      broken_links,
      introductions,
      replacements,
      this_edit.experiment_case)

    # For diagnostic/auditing purposes
    save_diffs this_edit, body, new_body, introductions, letters

    duration = Time.now - start_time
    $log.puts "Prepared for edit in #{duration} seconds"
    $log.puts

    # Save the changes to wikipedia
    commit_edits! this_edit, body, new_body, letters, remaining_links

    nil
  end

private

  def select_article_to_edit
    article_set = (LIMIT_EDIT_ARTICLES || @bad.keys)
    ready_articles = article_set.select {|art| article_ready? art}
    if ready_articles.empty?
      $log.puts "Nothing to edit."
      wait
      return
    end

    $log.puts "Selecting an article to edit..."

    # Tournament selection: choose best among a random group
    best_article = nil
    best_score = 0
    5.times do
      article = ready_articles[ rand( ready_articles.size ) ]
      score = article_edit_priority article
      if score > best_score
        best_article = article
        best_score   = score
      end
    end
    best_article
  end

  # Give priority to some articles.
  # Bigger is better.
  def article_edit_priority art
    base = Time.now
    sum = 0
    @bad[art].each do |link|
      # Favor articles with more broken
      # links, and which have been sitting
      # in @bad longer.
      sum += base - link.first_check_time
    end
    sum
  end

  def commit_edits! this_edit,old_body,new_body,letters, remaining_links

    name    = this_edit.title

    # Throttle the edit rate
    sleep_or_cancel(next_edit_time - Time.now)

    start_time = Time.now

    # Record edit stats which may throttle future edits
    # (even though we don't know if they will be performed / succeed)
    edit_dirty!
    @numEditsOnLastDay = numEditsToday + 1
    @lastEdit = start_time
    @editTimes << start_time

    return if $cancel

    unless ENABLE_EDITS_TO_LIVE_SITE
      $log.puts
      $log.puts "Edits to live site disabled."
      $log.puts
      return
    end

    if SAVE_EDITS_TO_USERSPACE
      mocks,old_rev = retrieve_article MOCK_EDIT_ARTICLE
      if mocks == nil or mocks.strip == ''
        mocks = "__NOINDEX__\n{{User page}}\n"
      end

      if mocks.size < MOCK_EDIT_SIZE_LIMIT
        diffs = compute_diffs(old_body,new_body)
        if diffs.size > 0
          mocks << "==#{name}==\n"
          mocks << diffs
          Api.session( BOT_USERNAME, BOT_PASSWORD ) do |session|
            $log.puts "Submitting mock-edit to wikipedia..."
            result, revid = session.replace(
              MOCK_EDIT_ARTICLE,old_rev,
              "Mock edit #{name}", mocks)
            $log.puts "--> #{result}"
          end
        end
      end
    end

    if TRIAL_MAX_EDITS
      if @numEdits >= TRIAL_MAX_EDITS
        $log.puts
        $log.puts "We have reached max-edits for the trial period"
        $log.puts
        return
      end
    end

    if TRIAL_MAX_NOTIFICATIONS
      if @numSolicitations >= TRIAL_MAX_NOTIFICATIONS
        $log.puts
        $log.puts "We have reached max-notifications for the trial period"
        $log.puts
        return
      end
    end

    old_rev = this_edit.old_rev_time
    message = this_edit.message
    expcase = this_edit.experiment_case

    $log.puts "COMMIT: '#{name}' '#{message}' in case #{ expcase }"

    # Commit changes to wikipedia
    unless expcase.no_connect?
      Api.session( BOT_USERNAME, BOT_PASSWORD ) do |session|

        if expcase.do_edit
          $log.puts "Submitting edit to wikipedia..."
          result, revid = session.replace(name,old_rev, message,new_body)
          if result == 'Success'

            $log.puts " -> Edit successful"
            this_edit.new_revision_id = revid

            edit_dirty!
            @numEdits += 1

            # Remove those problem links which have been completely fixed.
            if remaining_links.empty?
              $log.puts "  Fixed ALL bad links in this article :)"
              bad_links_dirty!
              @bad.delete name

            elsif remaining_links.size < @bad[name].size
              $log.puts "  Some bad links remain :("
              bad_links_dirty!
              @bad[name] = remaining_links
            end

          else
            $log.puts " -> Edit failed: #{result} #{revid}"
            this_edit.valid_data_point = false
          end
        end

        # Now solicit help.
        if expcase.do_solicit and this_edit.valid_data_point
          $log.puts "Sending solicitations..."

          letters.each do |sol_user, sol_subject, sol_msg|
            $log.puts " - #{sol_user}..."

            if throttle_solicitation? sol_user
              $log.puts " - Too soon to contact this user again."
              next
            end

            result,sol_revid = session.send_message_to sol_user, sol_subject, sol_msg

            case result
            when 'Success'
              sent_a_solicitation! sol_user
              this_edit.solicitations << [sol_user, sol_revid]

            when 'Refused'
              # The message was filtered by our 'firewall'
              # This is fine, but don't record it 'cause
              # the user will never see it.

            else
              # Some sort of network failure,
              # edit conflict, etc?
              this_edit.valid_data_point = false
            end

            $log.puts " --> #{result}"
          end
        end

      end
    end

    # Record this edit.  It will be read again
    # later by the revert-checking code.
    previous_edits_dirty!
    @previous_edits[name] ||= []
    @previous_edits[name] << this_edit

    # Some statistics we can record immediately.
    if this_edit.valid_data_point
      key = this_edit.experiment_case.to_s

      add_stat key, 'contributing_links', this_edit.bad_links.size
      add_stat key, 'archived_num_places', this_edit.nArchived
      add_stat key, 'marked_dead_num_places', this_edit.nBroken
      add_stat key, 'unfixed_num_places', this_edit.nUnfixed
      add_stat key, 'introductions_distict_users', letters.size
      add_stat key, 'num_solicitations', this_edit.solicitations.size
    end

    duration = Time.now - start_time
    $log.puts "Commit edit in #{duration} seconds"
    $log.puts
  end

  def should_start_edit?
    net = next_start_edit_time
    (net != nil) and (net <= Time.now)
  end

  def should_edit?
    net = next_edit_time
    (net != nil) and (net <= Time.now)
  end

  def next_edit_time
    if edit_starved?
      return nil

    else
      instantaneous_limit = @lastEdit + edit_period

      daily_limit = nil
      if MAX_EDITS_PER_DAY
        if numEditsToday >= MAX_EDITS_PER_DAY
          daily_limit = Time.tomorrow.morning
        end
      end

      article_set = (LIMIT_EDIT_ARTICLES || @bad.keys)
      earliest_ready = article_set.map {|article| earliest_next_edit_time article}.compact.min

      t = [instantaneous_limit, daily_limit, earliest_ready, $maxlag_until].compact.max
      $log.puts "* Next edit at #{t}"
      return t
    end
  end

  def next_start_edit_time
    net = next_edit_time

    return nil if net==nil
    (net - ESTIMATED_EDIT_PREPARE_LATENCY)
  end

  def edit_starved?
    # starvation == no articles to edit.

    if LIMIT_EDIT_ARTICLES
      LIMIT_EDIT_ARTICLES.each do |article|
        return false if @bad.has_key? article and not @bad[article].empty?
      end
      return true

    else
      # Normal.
      return @bad.empty?
    end
  end

  def numEditsToday
    if @lastEdit.yday == Time.now.yday
      return @numEditsOnLastDay
    else
      return 0
    end
  end

  def last_edit_time article
    return nil unless @previous_edits.has_key? article
    @previous_edits[article].map {|rv| rv.edit_time}.max
  end

  def earliest_next_edit_time article
    return nil unless @bad.has_key? article
    return nil if @bad[article].empty?

    # Two factors determine if this article is ready.

    # If we have editted this article in the past,
    # ensure that enough time has passed to avoid edit wars.
    last = last_edit_time article
    if last
      min_edit_per_article = last + MIN_EDIT_PERIOD_PER_ARTICLE
    else
      min_edit_per_article = Time.now
    end

    # Since the pipeline checks one link at a time, there is
    # a short awkward period when the article is in @bad, but
    # more links are expected to arrive soon.  ''quiescence.''
    quiescence = @bad[article].map {|link| link.last_check_time}.max + MIN_QUIESCENCE_PERIOD_ARTICLE

    return [min_edit_per_article, quiescence].max
  end

  def article_ready? article
    enet = earliest_next_edit_time article
    (enet != nil) and (enet <= Time.now)
  end

  def suitable? date, repl_date
    return false if date==nil
    return false if repl_date==nil
    (date-repl_date).abs <= MAX_DATE_ERROR_FOR_ARCHIVES
  end

  # Write a record of an edit
  # - name: article name
  # - body: old version of article text
  # - revision: time of creation of this revision
  # - message: human-readable summary of change
  # - apologies for each link
  # - a copy of the solicitations sent
  # - diff
  def save_diffs this_edit, body, new_body, introductions, letters
    return unless SAVE_EDITS_LOCALLY

    name = this_edit.title
    revision = this_edit.old_rev_time
    message = this_edit.message
    exp_case = this_edit.experiment_case
    contributing_bad_links = this_edit.bad_links

    now = Time.now
    day_dir = edit_log_dir now
    Dir.mkdir_p day_dir

    prefix = name.gsub(/[^0-9a-zA-Z]/, '_')
    basename = "#{ prefix }.#{ now.strftime "%H:%M:%S" }"

    # Save old version
    before = "#{day_dir}/#{basename}.before"
    File.atomic_create before do |b|
      linewrap b, body
    end

    # Save new version
    after  = "#{day_dir}/#{basename}.after"
    File.atomic_create after do |a|
      linewrap a, new_body
    end

    # Save the message
    msgfile = "#{day_dir}/#{basename}.message"
    File.atomic_create msgfile do |m|
      m.puts "Article: #{name}"
      m.puts "Source revision: #{revision}"
      m.puts "Edit time: #{Time.now}"
      m.puts "Experiment case: #{exp_case}"
      m.puts "Message: #{message}"

      m.puts

      m.puts "Apologies:"
      contributing_bad_links.each do |link|
        m.puts link.url
        m.puts link.apologize

        intro = introductions[link.url]
        next if intro == nil
        m.puts "  This link was introduced"
        m.puts "    in revision #{ intro[0] }"
        m.puts "    on #{ intro[1] }"
        m.puts "    by #{ intro[2] }"
        m.puts "    who said #{ intro[3] }"

        m.puts
      end

      m.puts

      m.puts "Solicitations:"
      letters.each do |recipient,subject,message|
        m.puts
        m.puts "To: #{recipient}"
        m.puts "Subject: #{subject}"
        m.puts "Body:"
        m.puts message
      end

      m.puts
    end

    # Compute diff, append it to message
    system "diff --unified=6 --minimal #{before} #{after} >>#{msgfile} 2>/dev/null"

#    # Remove the old,new versions
#    File.delete before
#    File.delete after

    # Compress yesterday's logs.
    compress_logs Time.yesterday
  end

  def compress_logs yester
    return unless SAVE_EDITS_LOCALLY

    archive_file = edit_log_archive yester

    # Already archived?
    return if File.exists? archive_file

    # Create an archive
    log_dir = edit_log_dir yester
    return unless File.directory? log_dir

    $log.puts "Compressing edit logs #{log_dir} => #{archive_file} ..."
    start = Time.now
    Dir.chdir(edit_log_mdir yester) do
      system "tar cjf #{archive_file} --remove-files #{yester.day}"
    end
    $log.puts "Done compressing logs, #{Time.now - start} seconds."
  end

  def edit_log_ydir time
    "#{EDITS_DIR}/#{time.year}"
  end

  def edit_log_mdir time
    "#{edit_log_ydir time}/#{time.month}"
  end

  def edit_log_dir time
    "#{edit_log_mdir time}/#{time.day}"
  end

  # Get the name of the day's archive
  def edit_log_archive time
    "#{edit_log_dir time}.tar.bz2"
  end

  # Every once in a while, clean out some cruft.
  def manage_bad_links
    return if @bad.size <= MAX_BAD_LINK_POOL

    $log.print "Pruning bad link pool #{@bad.size} -> "
    bad_links_dirty!

    # First, try to remove links that we don't
    # know how to fix.
    @bad.each_pair do |article, links|
      links.delete_if { |link| link.cannot_be_fixed? }
      if links.empty?
        @bad.delete article
        if @bad.size <= MIN_BAD_LINK_POOL
          $log.puts @bad.size
          return
        end
      end
    end

    # Next, try to remove the oldest links
    # TODO

    $log.puts @bad.size
  end

end

