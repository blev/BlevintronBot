
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
require 'source'

$log ||= $stderr

class HostStats
  def initialize
    @num_ok = 0
    @num_good_enough = 0
    @num_redirects = 0
    @num_bad = 0
  end

  attr_accessor :num_ok, :num_good_enough
  attr_accessor :num_redirects, :num_bad
end

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



class DB
  def initialize(robots = nil, frags = nil, bads = nil, prevs = nil, stats = nil)
    if stats == nil

      @fragments = Array.new(NUM_FRAGMENTS) { Hash.new }
      @bad = {}

      @previous_edits = {}

      @lastScrape = Time.now - HIGH_TRAFFIC_EDIT_PERIOD
      @lastEdit   = Time.now
      @numEditsOnLastDay = 0
      @numEdits = 0

      @numRevertedEdits = 0
      @numNonRevertedEdits = 0
      @numSolicitations = 0

      @lastSourceCodeUpload = Time.now - MIN_SOURCE_CODE_UPLOAD_PERIOD
      @lastStatsUpload = Time.now - MIN_STATS_UPLOAD_PERIOD
      @experiment_stats_dirty = true

      @robotstxt = {}

      @first_run_time = Time.now

      @numBad = 0
      @numRedirects = 0
      @numArticlesVisited = 0
      @numOkLinks = 0
      @numGoodEnoughLinks = 0

      @host_stats = {}
      @experiment_stats = {}
      @solicits_per_user = {}

      dirty!

    else
      @robotstxt          = robots
      @fragments          = frags
      @bad                = bads

      @previous_edits     = prevs

      @first_run_time     = stats['first_run_time']

      @lastScrape         = stats['lastScrape']
      @lastEdit           = stats['lastEdit']
      @numEditsOnLastDay  = stats['numEditsOnLastDay']
      @numEdits           = stats['numEdits']

      @numRevertedEdits   = stats['numRevertedEdits']
      @numNonRevertedEdits= stats['numNonRevertedEdits']
      @numSolicitations   = stats['numSolicitations']

      @lastSourceCodeUpload = stats['lastSourceCodeUpload']
      @lastStatsUpload    = stats['lastStatsUpload']
      @experiment_stats_dirty = stats['experiment_stats_dirty']

      @numBad             = stats['numBad']
      @numRedirects       = stats['numRedirects']
      @numArticlesVisited = stats['numArticlesVisited']
      @numOkLinks         = stats['numOkLinks']
      @numGoodEnoughLinks = stats['numGoodEnoughLinks']

      if MAINTAIN_HOST_STATS
        @host_stats       = stats['host_stats']
      else
        @host_stats  = {}
      end

      @experiment_stats   = stats['experiment_stats']
      @solicits_per_user  = stats['solicits_per_user']

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
      bads = load_object "#{dir}/bad"
      prevs = load_object "#{dir}/previous_edits"
      stats = load_object "#{dir}/stats"

      return DB.new(robots, frags, bads, prevs, stats)

    rescue Exception => e
      $log.puts "Error loading database from file: #{e}"
      return DB.new
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

      # Save statistics, etc
      if stats_dirty?
        $log.print 's'
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
        stats['host_stats'] = @host_stats

        # These are used by the editing process.
        stats['lastEdit'] = @lastEdit
        stats['numEditsOnLastDay'] = @numEditsOnLastDay
        stats['numEdits'] = @numEdits
        stats['lastSourceCodeUpload'] = @lastSourceCodeUpload
        stats['lastStatsUpload'] = @lastStatsUpload
        stats['experiment_stats_dirty'] = @experiment_stats_dirty
        stats['numRevertedEdits'] = @numRevertedEdits
        stats['numNonRevertedEdits'] = @numNonRevertedEdits
        stats['numSolicitations'] = @numSolicitations
        stats['experiment_stats'] = @experiment_stats
        stats['solicits_per_user'] = @solicits_per_user

        save_object stats, "#{dir}/stats"
      end

      $log.puts " #{Time.now - start} seconds"

    rescue Exception => e
      $log.puts "Exception while saving db: #{e}"
    end

    not_dirty!
  end

  def clear_experiment_stats!
    stats_dirty!
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
    @robots_dirty = true
    @fragment_dirty = [true] * NUM_FRAGMENTS
    @bad_links_dirty = true
    @previous_edits_dirty = true
    @stats_dirty = true
  end

  def robots_dirty!
    @robots_dirty = true
  end

  def fragment_dirty! f
    @fragment_dirty[f] = true
  end

  def bad_links_dirty!
    @bad_links_dirty = true
  end

  def previous_edits_dirty!
    @previous_edits_dirty = true
  end

  def stats_dirty!
    @stats_dirty = true
  end

  def experiment_stats_dirty!
    @experiment_stats_dirty = true
  end

  def experiment_stats_dirty?
    @experiment_stats_dirty
  end

  def next_action_time
    [next_scrape_time, next_check_link_time, next_edit_time].compact.min
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

  def print_stats
    $log.puts "- - - - - - - - - - - - - - - - - -"
    $log.puts "DB Stats #{Time.now}"
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

    $log.puts "- #{ @bad.size } articles have problem links and are waiting for edit."
    $log.puts "- Watching previous actions on #{ @previous_edits.size } articles"
    $log.puts "- robots.txt cache: #{ @robotstxt.size }"
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
    @robots_dirty = false
    @fragment_dirty = [false] * NUM_FRAGMENTS
    @bad_links_dirty = false
    @previous_edits_dirty = false
    @stats_dirty = false
  end

  def robots_dirty?
    @robots_dirty
  end

  def fragment_dirty? f
    @fragment_dirty[f]
  end

  def bad_links_dirty?
    @bad_links_dirty
  end

  def previous_edits_dirty?
    @previous_edits_dirty
  end

  def stats_dirty?
    @stats_dirty
  end
end
