#!/usr/bin/ruby -w

## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: main driver program

require 'net/http'
require 'uri'

require 'db'
require 'tmux'
require 'object_queue'

# Maybe write output to a log file.
$log = $stderr
if LOG_FILE
  $log = File.open LOG_FILE, 'a'
end

# Global shutdown flag
$cancel = false

# Write a PID file
def save_pid fn
  File.atomic_create fn do |pidout|
    pidout.puts Process.pid
  end
end

def trap_signals
  # Make it easy to shut down from the terminal.
  trap "INT" do
    exit if $cancel

    $log.puts
    $log.puts "****** Received CTRL-C ******"
    $log.puts "Please wait, while I shut-down cleanly."
    $log.puts "Or, hit CTRL-C again to exit immediately."
    $log.puts "****** Received CTRL-C ******"
    $log.puts
    $log.flush

    $cancel = true
  end
  $log.puts "Hit CTRL-C for clean shutdown..."

  # Receive this before system shutdown
  trap "TERM" do
    $log.puts
    $log.puts "****** System shutdown ******"
    $log.puts
    $log.flush

    $cancel=true
  end
end

def scraper_task
  $log = TMux.new($log, 0)
  $log.puts "Startup scraper: #{Time.now}"
  save_pid SCRAPER_PID_FILE
  scraper = Scraper.load DB_DIR
  trap_signals

  until $cancel
    scraper.print_scrape_stats

    # Keep CPU, Network utilization low
    scraper.wait
    break if $cancel

    # I run this on my laptop in the background.
    # No point in wasting battery.
    if on_battery_power?
      $log.puts "Idle: on battery power..."
      sleep_or_cancel BATTERY_WAIT
      next
    end

    # Contact my emergency shutdown page.
    if emergency_shutdown_check == :bad_network
      $log.puts "Idle: network is down..."
      sleep_or_cancel NETWORK_WAIT
      next
    end

    # Find more links
    scraper.scrape!

    # Check link quality
    scraper.check_links!

    # Save the database to persistent storage
    scraper.save DB_DIR
  end


  scraper.print_scrape_stats

  File.delete SCRAPER_PID_FILE
  $log.puts "Shutdown scraper: #{Time.now}"
  $log.flush
  exit
end

def editor_task
  $log = TMux.new($log, TMUX_COLUMN_WRAP)
  $log.puts "Startup editor: #{Time.now}"
  save_pid EDITOR_PID_FILE
  editor  = Editor.load DB_DIR
  trap_signals

  edits_allowed = true
  until $cancel

    editor.print_edit_stats

    editor.receive_links $q

    # Keep CPU, Network utilization low
    editor.wait
    break if $cancel

    # I run this on my laptop in the background.
    # No point in wasting battery.
    if on_battery_power?
      $log.puts "Idle: on battery power..."
      sleep_or_cancel BATTERY_WAIT
      next
    end

    # Contact my emergency shutdown page.
    case emergency_shutdown_check
    when :bad_network
      $log.puts "Idle: network is down..."
      sleep_or_cancel NETWORK_WAIT
      next

    when :good
      $log.puts "Edits are allowed again :)" unless edits_allowed
      edits_allowed = true

    when :shutdown
      $log.puts "Edits are prohibited..."
      edits_allowed = false
    end

    # Perform editing
    if edits_allowed
      editor.perform_edits!
    end

    # Check if my changes were reverted,
    # and maybe do something about that.
    editor.check_previous_edits!

    # Upload my stats
    editor.upload_stats!

    # Save the database to persistent storage
    editor.save DB_DIR
  end

  editor.receive_all_links $q
  editor.save DB_DIR

  editor.print_edit_stats

  File.delete EDITOR_PID_FILE
  $log.puts "Shutdown editor: #{Time.now}"
  $log.flush
  exit
end


$log.puts
$log.puts "Startup: #{Time.now}"
$log.puts
$log.puts "This is #{BOT_NAME} version #{BOT_VERSION}"
$log.puts "(C) 2012 Blevintron"
$log.puts "This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt"
$log.puts

trap_signals
save_pid PID_FILE

scraper_pid = editor_pid = nil
$q = ObjectQueue.new
until $cancel
  # Start the tasks, if they are not running.
  unless scraper_pid
    scraper_pid = fork { scraper_task }
  end
  unless editor_pid
    editor_pid = fork { editor_task }
  end

  # Check if either has died for some reason...
  case Process.wait
  when scraper_pid
    scraper_pid = nil
    unless $cancel
      $log.puts "The Scraper task has died for some reason..."
      $log.flush
      sleep 1
    end
  when editor_pid
    editor_pid = nil
    unless $cancel
      $log.puts "The Editor task has died for some reason..."
      $log.flush
      sleep 1
    end
  end
end

Process.waitpid scraper_pid if scraper_pid

$q.send :scraper_shutdown
$q.close_sender

Process.waitpid editor_pid  if editor_pid
$q.close_receiver

File.delete PID_FILE
$log.puts "Shutdown: #{Time.now}"
$log.flush



