
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: main database storage; marshaling to/from persistent storage.

require 'zlib'

require 'config'
require 'link'
require 'throttling'
require 'markup'
require 'rexml/document'
require 'yaml'
require 'utils'

# The definition of class DB is divided
# across several files, approximately by function.
require 'check'
require 'edit'
require 'nobots'
require 'reverts'
require 'scrape'

$log ||= $stderr

def save_object obj, filename
  format = SAVE_DB_FORMAT

  if format == '.marshal.gz'
    begin
      File.atomic_create(filename + '.marshal.gz') do |fout|
        begin
          gzout = Zlib::GzipWriter.new fout
          Marshal.dump obj, gzout
        ensure
          gzout.close
        end
      end

    rescue Exception => e
      # Upon failure, fall-back to .yaml
      $log.puts
      $log.puts "Failed to save to #{filename}.marshal.gz: #{e}"

      # Why did it fail?  (i.e. I've observed it fail, but I don't think there
      # should be any IO/Singleton/Procs in the database. so... WHY!?)
      obj.test_marshal

      # At least yaml is reliable.  Or maybe it silently ignores errors :)
      $log.puts " -> Fall-back to .yaml"
      format = '.yaml'
    end
  end

  if format == '.yaml'
    File.atomic_create(filename + '.yaml') do |fout|
      YAML.dump obj, fout
    end
  end
end

# Load either .yaml or .marshal.gz.
# Give a warning if both exist.
# Break ties by modification time.
def load_object filename
  yaml = filename + '.yaml'
  mgz  = filename + '.marshal.gz'

  use_yaml = File.exist? yaml
  use_mgz  = File.exist? mgz

  if use_yaml and use_mgz
    $log.puts "Warning: both .yaml and .marshal.gz versions exist: #{filename}"

    # Select the newest
    if (File.stat yaml).mtime > (File.stat mgz).mtime
      $log.puts " -> The .yaml version is newer."
      use_mgz = false
    else
      $log.puts " -> The .marshal.gz version is newer."
      use_yaml = false
    end
  end


  if use_yaml
    return YAML.load_file yaml

  elsif use_mgz
    return Zlib::GzipReader.open(mgz) {|fin| Marshal.load fin}

  else
    raise(Exception.new "Neither .yaml nor .marshal.gz versions exist: #{filename}")
  end
end

class Scraper
  def initialize(robots = nil, frags = nil, scrapedb = nil)
    if scrapedb == nil

      @fragments = Array.new(NUM_FRAGMENTS) { Hash.new }

      @lastScrape = Time.now - HIGH_TRAFFIC_EDIT_PERIOD
      @lastEdit   = Time.now

      @robotstxt = {}

      @first_run_time = Time.now

      @numBad = 0
      @numRedirects = 0
      @numArticlesVisited = 0
      @numOkLinks = 0
      @numGoodEnoughLinks = 0

      dirty!

    else
      @robotstxt          = robots
      @fragments          = frags

      @first_run_time     = scrapedb['first_run_time']
      @lastScrape         = scrapedb['lastScrape']
      @numBad             = scrapedb['numBad']
      @numRedirects       = scrapedb['numRedirects']
      @numArticlesVisited = scrapedb['numArticlesVisited']
      @numOkLinks         = scrapedb['numOkLinks']
      @numGoodEnoughLinks = scrapedb['numGoodEnoughLinks']

      not_dirty!
    end

    build_link_check_schedule
  end

  def self.load(dir)
    $log.puts "Loading database from persistent storage"
    begin
      robots = load_object "#{dir}/robots"
      frags = []
      for i in 0 ... NUM_FRAGMENTS
        frags[i] = load_object "#{dir}/fragment-#{i}"
        $log.puts "- Fragment #{i} has #{ frags[i].size } links"
      end

      scrapedb = load_object "#{dir}/scrape-db"
      return Scraper.new(robots, frags, scrapedb)

    rescue Exception => e
      $log.puts "Error loading database from file: #{e}"
      return Scraper.new
    end
  end

  def save(dir)
    begin
      start = Time.now
      $log.print "Saving database to persistent storage... "

      # Make directory, if it doesn't already exist.
      begin
        Dir.mkdir dir
      rescue Exception => e
        # directory already exists
      end

      # Save robots.txt cache
      if robots_dirty?
        $log.print 'r'
        save_object @robotstxt, "#{dir}/robots"
      end

      # Save each fragment of the questionable
      # links which are dirty.
      for i in 0...NUM_FRAGMENTS
        if fragment_dirty? i
          $log.print i
          save_object @fragments[i], "#{dir}/fragment-#{i}"
        end
      end

      # Save statistics, etc
      if scrape_dirty?
        $log.print 'S'
        # This is a sloppy mess. clean it up.
        stats = {}

        # These are used by the scraping/checking process
        stats['first_run_time'] = @first_run_time
        stats['lastScrape'] = @lastScrape
        stats['numBad'] = @numBad
        stats['numRedirects'] = @numRedirects
        stats['numArticlesVisited'] = @numArticlesVisited
        stats['numOkLinks'] = @numOkLinks
        stats['numGoodEnoughLinks'] = @numGoodEnoughLinks

        save_object stats, "#{dir}/scrape-db"
      end

      $log.puts " #{Time.now - start} seconds"

    rescue Exception => e
      $log.puts "Exception while saving db: #{e}"
    end

    not_dirty!
  end

  def dirty!
    @robots_dirty = true
    @fragment_dirty = [true] * NUM_FRAGMENTS
    @scrape_dirty = true
  end

  def robots_dirty!
    @robots_dirty = true
  end

  def fragment_dirty! f
    @fragment_dirty[f] = true
  end

  def scrape_dirty!
    @scrape_dirty = true
  end

  def next_action_time
    [next_scrape_time, next_check_link_time].compact.min
  end

  def wait
    wait_until = next_action_time
    delay = EPSILON_WAIT
    if wait_until
      delay = wait_until - Time.now
      $log.print "Nothing to do until #{wait_until}... " if delay > 0
    end

    delay = EPSILON_WAIT if delay < EPSILON_WAIT
    delay = MAX_IDLE_WAIT if delay > MAX_IDLE_WAIT

    $log.puts "sleeping #{ delay.ceil } seconds"
    sleep_or_cancel delay
  end

  def print_scrape_stats
    $log.puts "- - - - - - - - - - - - - - - - - -"
    $log.puts "Scrape Stats #{Time.now}"
    $log.puts "- Visited #{ @numArticlesVisited } articles"
    $log.puts "- Found #{ sprintf "%7d", @numOkLinks         } good links         ; #{ sprintf "%.3f", (@numOkLinks.to_f / @numArticlesVisited) } per article"
    $log.puts "- Found #{ sprintf "%7d", @numBad             } bad links          ; #{ sprintf "%.3f", (@numBad.to_f / @numArticlesVisited) } per article"
    $log.puts "- Found #{ sprintf "%7d", @numRedirects       } redirect links     ; #{ sprintf "%.3f", (@numRedirects.to_f / @numArticlesVisited) } per article"
    $log.puts "- Found #{ sprintf "%7d", @numGoodEnoughLinks } good-enough links  ; #{ sprintf "%.3f", (@numGoodEnoughLinks.to_f / @numArticlesVisited) } per article"
    $log.puts "- Found #{ sprintf "%7d", num_undecided       } undecided links    ; #{ sprintf "%.3f", (num_undecided.to_f / @numArticlesVisited) } per article"
    $log.puts

    known_not_ok = @numBad + @numRedirects + @numGoodEnoughLinks
    not_ok = num_undecided + known_not_ok
    p_not_ok = not_ok.to_f / (@numOkLinks + not_ok)

    p_bad_given_not_ok = @numBad.to_f / known_not_ok
    p_bad = p_bad_given_not_ok * p_not_ok

    p_redir_given_not_ok = @numRedirects.to_f / known_not_ok
    p_redir = p_redir_given_not_ok * p_not_ok

    p_enough_given_not_ok = @numGoodEnoughLinks.to_f / known_not_ok
    p_enough = p_enough_given_not_ok * p_not_ok

    $log.puts "From these, I can estimate:"
    $log.puts " #{ sprintf "%2.3f", (100 * p_bad)}% of links are BAD"
    $log.puts " #{ sprintf "%2.3f", (100 * p_redir)}% of links are consistent redirects"
    $log.puts " #{ sprintf "%2.3f", (100 * p_enough)}% of links are good enough"
    $log.puts
    $log.puts "- robots.txt cache: #{ @robotstxt.size }"
    $log.puts "- - - - - - - - - - - - - - - - - -"
  end

private

  def not_dirty!
    @robots_dirty = false
    @fragment_dirty = [false] * NUM_FRAGMENTS
    @scrape_dirty = false
  end

  def robots_dirty?
    @robots_dirty
  end

  def fragment_dirty? f
    @fragment_dirty[f]
  end

  def scrape_dirty?
    @scrape_dirty
  end

end

class Editor
  def initialize(bads = nil, prevs = nil, editdb = nil)
    if editdb == nil

      @bad = {}
      @previous_edits = {}
      @lastEdit   = Time.now
      @numEditsOnLastDay = 0
      @numEdits = 0

      @numRevertedEdits = 0
      @numNonRevertedEdits = 0
      @numSolicitations = 0

      @lastStatsUpload = Time.now - MIN_STATS_UPLOAD_PERIOD
      @experiment_stats_dirty = true

      @experiment_stats = {}
      @solicits_per_user = {}

      dirty!

    else
      @bad                = bads
      @previous_edits     = prevs

      @lastEdit               = editdb['lastEdit']
      @numEditsOnLastDay      = editdb['numEditsOnLastDay']
      @numEdits               = editdb['numEdits']
      @numRevertedEdits       = editdb['numRevertedEdits']
      @numNonRevertedEdits    = editdb['numNonRevertedEdits']
      @numSolicitations       = editdb['numSolicitations']
      @lastStatsUpload        = editdb['lastStatsUpload']
      @experiment_stats_dirty = editdb['experiment_stats_dirty']
      @experiment_stats       = editdb['experiment_stats']
      @solicits_per_user      = editdb['solicits_per_user']

      not_dirty!
    end

    @scraper_is_done = false
  end

  def self.load(dir)
    $log.puts "Loading database from persistent storage"
    begin
      bads = load_object "#{dir}/bad"
      prevs = load_object "#{dir}/previous_edits"

      editdb = load_object "#{dir}/edit-db"
      return Editor.new(bads, prevs, editdb)

    rescue Exception => e
      $log.puts "Error loading database from file: #{e}"
      return Editor.new
    end
  end

  def save(dir)
    begin
      start = Time.now
      $log.print "Saving database to persistent storage... "

      # Make directory, if it doesn't already exist.
      begin
        Dir.mkdir dir
      rescue Exception => e
        # directory already exists
      end

      # Save the bad links
      if bad_links_dirty?
        $log.print 'b'
        save_object @bad, "#{dir}/bad"
      end

      # Save previous edits
      if previous_edits_dirty?
        $log.print 'p'
        save_object @previous_edits, "#{dir}/previous_edits"
      end

      if edit_dirty?
        $log.print 'E'

        # This is a sloppy mess. clean it up.
        stats = {}

        # These are used by the editing process.
        stats['lastEdit'] = @lastEdit
        stats['numEditsOnLastDay'] = @numEditsOnLastDay
        stats['numEdits'] = @numEdits
        stats['lastStatsUpload'] = @lastStatsUpload
        stats['experiment_stats_dirty'] = @experiment_stats_dirty
        stats['numRevertedEdits'] = @numRevertedEdits
        stats['numNonRevertedEdits'] = @numNonRevertedEdits
        stats['numSolicitations'] = @numSolicitations
        stats['experiment_stats'] = @experiment_stats
        stats['solicits_per_user'] = @solicits_per_user

        save_object stats, "#{dir}/edit-db"
      end

      $log.puts " #{Time.now - start} seconds"

    rescue Exception => e
      $log.puts "Exception while saving db: #{e}"
    end

    not_dirty!
  end

  def receive_links q
    return if @scraper_is_done

    while true
      obj = q.receive

      case obj
      when Link
        receive_link obj
      when :scraper_shutdown
        @scraper_is_done = true
        break
      when nil
        break
      end
    end
  end

  def receive_all_links q
    n = 1
    while true
      receive_links q
      break if @scraper_is_done
      $log.puts "Waiting for scraper to send the done token..."

      sleep [n,EPSILON_WAIT].min
      n += 1
    end
  end

  def receive_link link
    # Add to bad, group by article.
    link.articles.each do |article|
      @bad[article] ||= []
      @bad[article]  << link
      bad_links_dirty!
    end
  end

  def clear_experiment_stats!
    edit_dirty!
    @numEdits = 0
    @numEditsOnLastDay = 0
    @numRevertedEdits = 0
    @numNonRevertedEdits = 0
    @numSolicitations = 0
    @solicits_per_user = {}
    @experiment_stats = {}
    @experiment_stats_dirty = true
  end

  def dirty!
    @bad_links_dirty = true
    @previous_edits_dirty = true
    @edit_dirty = true
  end

  def bad_links_dirty!
    @bad_links_dirty = true
  end

  def previous_edits_dirty!
    @previous_edits_dirty = true
  end

  def edit_dirty!
    @edit_dirty = true
  end

  def experiment_stats_dirty!
    @experiment_stats_dirty = true
  end

  def next_action_time
    [next_edit_time].compact.min
  end

  def wait
    wait_until = next_action_time
    delay = EPSILON_WAIT
    if wait_until
      delay = wait_until - Time.now
      $log.print "Nothing to do until #{wait_until}... " if delay > 0
    end

    delay = EPSILON_WAIT if delay < EPSILON_WAIT
    delay = MAX_IDLE_WAIT if delay > MAX_IDLE_WAIT

    $log.puts "sleeping #{ delay.ceil } seconds"
    sleep_or_cancel delay
  end

  def print_edit_stats
    $log.puts "- - - - - - - - - - - - - - - - - -"
    $log.puts "Edit Stats #{Time.now}"
    $log.puts "- #{ @bad.size } articles have problem links and are waiting for edit."
    $log.puts "- Watching previous actions on #{ @previous_edits.size } articles"
    $log.puts
    $log.puts "Edits contributed: #{@numEdits} total; performed #{numEditsToday} actions today."

    sumRevert = @numRevertedEdits + @numNonRevertedEdits
    if sumRevert > 0
      revertRate = @numRevertedEdits.to_f / sumRevert
      
      $log.puts "  (#{@numRevertedEdits} reverted : #{ @numNonRevertedEdits } not reverted == #{ sprintf "%.3f", revertRate } revert rate)"
    end

    $log.puts "Total solicitations sent: #{@numSolicitations}"
    $log.puts

    if ENABLE_EDITS_TO_LIVE_SITE
      $log.puts "Edits to live site: ENABLED"
    else
      $log.puts "Edits to live site: DISABLED"
    end

    $log.puts "- - - - - - - - - - - - - - - - - -"
    $log.puts
  end

private

  def not_dirty!
    @bad_links_dirty = false
    @previous_edits_dirty = false
    @edit_dirty = false
  end


  def bad_links_dirty?
    @bad_links_dirty
  end

  def previous_edits_dirty?
    @previous_edits_dirty
  end

  def edit_dirty?
    @edit_dirty
  end

  def experiment_stats_dirty?
    @experiment_stats_dirty
  end

end
