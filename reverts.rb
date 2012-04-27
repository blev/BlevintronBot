
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: collect statistics about our actions and how the
## Description: the wikipedia community has responded.  Reverts? Fixes? etc.

require 'uri'
require 'net/http'
require 'rexml/document'

require 'utils'
require 'config'
require 'api'
require 'retrieve'

require 'editlog'

class Editor

  def upload_stats!
    return unless should_upload_stats?
    return if $cancel

    # TODO: upload stats here too

    do_upload_experiment
  end

  # Check all previous edits which are ready
  def check_previous_edits!
    return if $cancel

    # Find those edits which are old enough to
    # check for reverts.
    check_these = []
    @previous_edits.each do |article, rvs|
      rvs.each do |rv|
        if rv.had_time_for_review?
          check_these << rv
        end
      end
    end

    return if check_these.empty?

    $log.puts "Checking #{ check_these.size } edits for reverts"
    messages = ''
    raw_data_records = ''
    known_bots = { BOT_USERNAME => true }
    reconnect(INSECURE_API_URL) do |http|
      check_these.each do |past_edit|
        break if $cancel

        maxlag = check_edit past_edit, messages, raw_data_records, known_bots, http
        break if maxlag

        # Reverted or not, the edit has passed our threshhold for
        # watching it.  Remove it from the database.  This is the
        # last stop in the pipeline.
        previous_edits_dirty!
        @previous_edits[ past_edit.title ].delete past_edit
        if @previous_edits[ past_edit.title ].empty?
          @previous_edits.delete past_edit.title
        end

      end
    end

##    # old version of the raw data page
##    raw,rawdate = retrieve_article RAW_DATA_ARTICLE
##    unless raw.include? '<!-- ADD NEW RECORDS BEFORE HERE -->'
##      raw << "{| class=\"wikitable sortable\"\n"
##
##      columns = [
##        'Action time',
##        'Measured time',
##        'Article title',
##        'Valid data point?',
##        'Experiment case',
##        'Edit',
##        'Notifications',
##        'Reverted?',
##        'Improvement',
##        'Total Participation',
##        'Participation/Solicited Author',
##        'Fraction of Solicited Authors',
##        'Revert',
##        'Block article',
##        'Block notifications']
##      raw << "|-\n! #{ columns.join "\n! "}\n"
##      raw << "\n<!-- ADD NEW RECORDS BEFORE HERE -->\n"
##      raw << "|}\n"
##    end
##
##    insertpt = raw.index '<!-- ADD NEW RECORDS BEFORE HERE -->'
##    raw.insert(insertpt, raw_data_records)



    # Tell the operator about reverts
    if messages != ''
      Api.session( BOT_USERNAME, BOT_PASSWORD ) do |session|
        session.send_message_to( OPERATOR_USERNAME, "Revert notices #{Time.now.dm}", messages )
##        res,revid = session.replace RAW_DATA_ARTICLE, rawdate, 'Update to latest results', raw
##        $log.puts res
      end
    end
  end

  # Check a single, previous edit
  def check_edit past_edit, messages_out, raw_data_out, known_bots={}, http_in=nil
    reconnect(INSECURE_API_URL,http_in) do |http|
      title = past_edit.title
      $log.print " - '#{title}' on #{ past_edit.edit_time }... "

      # Get the lastest version
      latest_revision, date = retrieve_article_maxlag title, http
      # (if maxlag, we return to main event loop and do something else)
      return true if latest_revision==nil

      # Retrieve article history; check if we were reverted.
      history = retrieve_history title, http, past_edit.time, nil
      reverted, byWhom, revertRevId, why = past_edit.has_been_reverted? history
      if reverted
        $log.puts " ** Reverted by #{byWhom} because #{why}"
      end

      # Exclude from the study any edits where the operator was involved.
      history.each do |hist_revid, hist_date, hist_author, hist_comment|
        if hist_author == OPERATOR_USERNAME
          $log.puts " ** Excluded: #{OPERATOR_USERNAME} has edited this article..."
          past_edit.valid_data_point = false
          break
        end
      end

      imprvt = nil
      partcp_total = nil
      partcp_per_author = nil
      partcp_frac_of_authors = nil
      annoy_revert = nil
      annoy_block_article = nil
      annoy_block_user = nil

      # Collect additional data points
      # Measure: improvement, participation, annoyance
      if past_edit.valid_data_point

        # - Improvement:   How many of the links were fixed?
        #   inputs: latest version of article
        #   result: a fraction of all broken links that were fixed.
        #
        imprvt = past_edit.measure_improvement latest_revision

        # - Participation: Did the recipients of our solicitations
        #   contribute edits after our action?
        #   inputs: revision history of article
        #   result: a fraction of all recipients
        #
        partcp_total, partcp_per_author, partcp_frac_of_authors = past_edit.measure_participation history, known_bots, http

        # - Annoyance I:   Was our edit reverted?
        #   inputs: revision history of article
        #   result: true or false
        if past_edit.experiment_case.do_edit
          annoy_revert = reverted
          $log.puts " -- Annoyance: #{annoy_revert} reverted"
        end

        # - Annoyance II:  Was a bot-exclusion tag added to the article?
        #   inputs: latest version of article
        #   result: true or false
        #
        annoy_block_article = nil
        if past_edit.experiment_case.do_edit
          annoy_block_article = (wiki_forbids_bots? latest_revision)
          $log.puts " -- Annoyance: #{annoy_block_article} article block"
        end

        # - Annoyance III: Did the recipients of our solicitations block
        #   future solicitations?
        #   inputs: latest version of recipients' User: and User_talk: pages
        #   result: true or false
        #
        annoy_block_user = past_edit.measure_blocked_userpages http
      end

      $log.puts "Valid data point? #{past_edit.valid_data_point}"

      # Accumulate these statistics.
      if past_edit.valid_data_point
        key = past_edit.experiment_case.to_s

        add_stat key,'improvement',                      imprvt
        add_stat key,'partcp_total',                     partcp_total
        add_stat key,'partcp_per_solicited_author',      partcp_per_author
        add_stat key,'partcp_frac_of_solicited_authors', partcp_frac_of_authors
        add_stat key,'annoy_revert',                     annoy_revert
        add_stat key,'annoy_block_article',              annoy_block_article
        add_stat key,'annoy_block_user',                 annoy_block_user
      end

##      raw_data_out << "|-\n"
##      raw_data_out << "| #{past_edit.edit_time.getutc}\n"
##      raw_data_out << "| #{Time.now.getutc}\n"
##      raw_data_out << "| #{past_edit.title}\n"
##      raw_data_out << "| #{past_edit.valid_data_point ? 'valid' : 'not valid'}\n"
##
##      raw_data_out << "| #{past_edit.experiment_case}\n"
##
##      if past_edit.new_revision_id
##        raw_data_out << "| [[#{link_to_diff( past_edit.title, past_edit.new_revision_id)} | Edit]]\n"
##      else
##        raw_data_out << "| (no edit)\n"
##      end
##
##      if past_edit.solicitations.empty?
##        raw_data_out << "| (no notifications)\n"
##      else
##        raw_data_out << "| "
##        past_edit.solicitations.each do |sol_user, sol_revid|
##          raw_data_out << "[[#{link_to_diff("User talk:#{sol_user}", sol_revid)} | #{sol_user}]], "
##        end
##        raw_data_out << "\n"
##      end
##
##      if reverted
##        raw_data_out << "| [[#{link_to_diff(past_edit.title, revertRevId)} | Reverted by #{byWhom}]]\n"
##      else
##        raw_data_out << "| (not reverted)\n"
##      end
##
##      raw_data_out << "| #{imprvt ||''}\n"
##      raw_data_out << "| #{partcp_total ||''}\n"
##      raw_data_out << "| #{partcp_per_author ||''}\n"
##      raw_data_out << "| #{partcp_frac_of_authors ||''}\n"
##      raw_data_out << "| #{annoy_revert ||''}\n"
##      raw_data_out << "| #{annoy_block_article ||''}\n"
##      raw_data_out << "| #{annoy_block_user ||''}\n"

      # Global stats
      if past_edit.experiment_case.do_edit
        if reverted
          $log.puts "REVERTED by #{byWhom}."
          edit_dirty!
          @numRevertedEdits += 1
          upon_revert past_edit, byWhom, revertRevId, why, messages_out

        else
          $log.puts "still there :)"
          edit_dirty!
          @numNonRevertedEdits += 1
        end
      end
    end

    false
  end

  def do_upload_experiment
    edit_dirty!
    @lastStatsUpload = Time.now

    latest,expdate = retrieve_article EXPERIMENT_ARTICLE
    latest ||= ''

    [
     # These stats are recorded immediately after commiting
     # the edit (see edit.rb function commit_edit!)
     'contributing_links',
     'archived_num_places', 'marked_dead_num_places', 'unfixed_num_places',
     'introductions_distict_users', 'num_solicitations',
     # These stats are recorded after the revert timeframe
     # (this file)
     'improvement', 'partcp_total', 'partcp_per_solicited_author',
     'partcp_frac_of_solicited_authors', 'annoy_revert',
     'annoy_block_article', 'annoy_block_user',
    ].each do |exp|

      new_table = wikify_experiment exp

      if latest =~ /(<!-- BEGIN:#{exp} .* END:#{exp} -->)/m
        # Replace the table in-situ
        latest[$1] = new_table.strip

      else
        # Append it
        latest << new_table
      end
    end

    Api.session( BOT_USERNAME, BOT_PASSWORD ) do |session|
      $log.print "Uploading results..."
      res,revid = session.replace EXPERIMENT_ARTICLE, expdate, 'Update to latest results', latest
      $log.puts res

      @experiment_stats_dirty = false if res == 'Success'
    end

  end

private

  def add_stat key,name,val
    edit_dirty!
    experiment_stats_dirty!
    @experiment_stats[key] ||= {}
    @experiment_stats[key][name] ||= Statistic.new
    @experiment_stats[key][name].push val
  end


  # This is called when our old edit 'rv'
  # was reverted by user 'byWhom' in revision 'revId'.
  # Try to do something constructive.
  def upon_revert rv, byWhom, revId, summaryMsg, messages_out
    # Notify our operator.
    messages_out << "* My [#{link_to_diff rv.title, rv.new_revision_id} edits "
    messages_out << "on #{rv.edit_time.dm}] "
    messages_out << "to article '#{rv.title}' "
    messages_out << "were [#{link_to_diff  rv.title, revId} reverted].\n"
  end

  def should_upload_stats?
    (Time.now - @lastStatsUpload) >= MIN_STATS_UPLOAD_PERIOD and experiment_stats_dirty?
  end


  def wikify_experiment(variable,sout='')
    @experiment_stats['-E-S'] ||= {}
    @experiment_stats['+E-S'] ||= {}
    @experiment_stats['-E+S'] ||= {}
    @experiment_stats['+E+S'] ||= {}

    @experiment_stats['-E-S'][variable] ||= Statistic.new
    @experiment_stats['+E-S'][variable] ||= Statistic.new
    @experiment_stats['-E+S'][variable] ||= Statistic.new
    @experiment_stats['+E+S'][variable] ||= Statistic.new

    sout << "<!-- BEGIN:#{variable} -->\n"
    sout << "<!-- Please don't modify this table; it is "
    sout << "automatically updated by the bot once a day -->\n"
    sout << "{| class=\"wikitable\"\n"
    sout << "|-\n"
    sout << "!\n"
    sout << "! Don't mark broken links\n"
    sout << "! Mark broken links\n"
    sout << "|-\n"
    sout << "! Don't Solicit Help\n"
    sout << "| "
    @experiment_stats['-E-S'][variable].wikify(sout)
    sout << "\n| "
    @experiment_stats['+E-S'][variable].wikify(sout)
    sout << "\n|-\n! Solicit Help\n"
    sout << "| "
    @experiment_stats['-E+S'][variable].wikify(sout)
    sout << "\n| "
    @experiment_stats['+E+S'][variable].wikify(sout)
    sout << "\n|}\n"
    sout << "(as of #{Time.now.getutc})\n"
    sout << "<!-- END:#{variable} -->\n"

    sout
  end


end




