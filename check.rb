
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: code for checking links.

require 'liberal_uri'
require 'net/https'

require 'config'
require 'link'
require 'nobots'
require 'throttling'
require 'markup'
require 'utils'

class Scraper


  def check_links!
    start_check = Time.now

    # is there work to do...
    return if @link_schedule.empty?
    return unless @link_schedule.first.is_ready?

    $log.puts "Checking links..."

    # Get all ready links
    ready = []
    until @link_schedule.empty?
      break unless @link_schedule.first.is_ready?
      ready << @link_schedule.shift
    end

    # Group them by by (scheme, host, port)
    ready.sort! do |link1, link2|
      begin
        u1 = URI.liberal_parse link1.url
        u2 = URI.liberal_parse link2.url

        "#{u1.scheme} #{u1.host.downcase} #{u1.port}" <=> "#{u2.scheme} #{u2.host.downcase} #{u2.port}"

      rescue Exception => e
        link1.object_id <=> link2.object_id
      end
    end

    nReady = ready.size
    $log.puts "#{nReady} links are ready..."

    # Check all links which are ready
    nChecked = 0
    lastReport = 0
    nGroups = 0
    until ready.empty?
      break if $cancel

      nChecked += check_group_of_links! ready
      nGroups += 1

      if nChecked - lastReport >= 10
        $log.puts "                                                         (checked #{nChecked} of #{nReady})"
        lastReport = nChecked
      end

      # If we get too much of a back log,
      # we starve the other tasks, and there
      # is a greater risk that we will crash
      # before we save progress to disk.
      break if nChecked > 250
    end

    # If anything is left in ready
    # (for instance, if $cancel happened)
    # put that back at the FRONT of the schedule
    unless ready.empty?
      @link_schedule = ready + @link_schedule
    end

    throw "violated link_schedule invariant" if @link_schedule.size != num_undecided

    duration = Time.now - start_check
    rate = nChecked.to_f / duration
    $log.puts "Checked #{nChecked} links on #{nGroups} hosts; #{sprintf "%.2f", rate} links/second"
  end



private

  def check_group_of_links! ready
    nChecked = 0

    # Which group are we in?
    url = ready.first.url
    if pathological_url? url
      $log.puts "This URL is pathologically bad: '#{ready.first.url}'"
      group_scheme = nil
      group_host = nil
      group_port = nil

    else
      firstURI = URI.liberal_parse ready.first.url

      group_scheme = firstURI.scheme
      group_host = firstURI.host.downcase
      group_port = firstURI.port
    end

    $log.puts "#{group_scheme}://#{group_host}:#{group_port}"
    reconnect(firstURI) do |http|
      # Each link in this group
      until ready.empty?
        break if $cancel

        # Still in the same group?
        if pathological_url? ready.first.url
          $log.puts "WTF: '#{ready.first.url}'"
          raise(Exception.new 'malformed url')
        end

        uri = URI.liberal_parse ready.first.url

        break if uri.scheme != group_scheme
        break if uri.host.downcase != group_host
        break if uri.port != group_port

        # Check the link
        link = ready.shift
        fragment_dirty! link.fragno

        if robottxt_disallow?(uri, http)
          link.observation(RetrievalAttempt.norobots)

        else
          link.check! http
        end

        nChecked += 1
        reclassify_link link
      end
    end

    nChecked
  end

  def next_check_link_time
    if @link_schedule.empty?
      return nil

    else
      base = Time.now

      earliest = @link_schedule.first.next_check_time(base)
      latest = earliest + BATCH_LINK_WILLING_TO_WAIT

      worth_waiting_until = earliest
      n = 0
      @link_schedule.each do |link|
        link_time = link.next_check_time(base)

        if earliest < link_time and link_time <= latest
          worth_waiting_until = link_time

        elsif latest < link_time
          break
        end

        n += 1
      end

      $log.puts "* Next link-check at #{worth_waiting_until} for #{n} links"
      worth_waiting_until
    end
  end

  def build_link_check_schedule
    @link_schedule = []
    @fragments.each do |url2link|
      @link_schedule += url2link.values
    end

    base = Time.now
    @link_schedule.sort! do |link1, link2|
      link1.next_check_time(base) <=> link2.next_check_time(base)
    end
  end



  def remove_from_fragments link
    fragno = link.fragno

    @fragments[ fragno ].delete link.url
    fragment_dirty! fragno
  end

  def reclassify_link link
    # Re-classify the link
    if link.is_consistent_redirect?
      remove_from_fragments link

      scrape_dirty!
      @numRedirects += 1

      # Send this link to the editor task
      $q.send link

    elsif link.is_ok?
      remove_from_fragments link

      scrape_dirty!
      @numOkLinks += 1

    elsif link.is_good_enough?
      remove_from_fragments link

      scrape_dirty!
      @numGoodEnoughLinks += 1

    elsif link.is_bad?
      remove_from_fragments link

      scrape_dirty!
      @numBad += 1

      # Send this link to the editor task
      $q.send link

    else
      # Add it back onto the schedule
      @link_schedule.push link
    end
  end


end

