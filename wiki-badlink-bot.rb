#!/usr/bin/ruby -w


## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: main driver program

require 'net/http'
require 'uri'

require 'db'

# Maybe write output to a log file.
$log = $stderr
if LOG_FILE
  $log = File.open LOG_FILE, 'a'
end

# If we are writing to a terminal,
# don't die upon disconnect.
trap "HUP" do
  if $log.tty?
    $log = File.open '/dev/null', 'a'
  end

  $log.puts
  $log.puts "****** Received SIGHUP ******"
  $log.puts
  $log.flush
end

$log.puts
$log.puts "Startup: #{Time.now}"
$log.puts
$log.puts "This is #{BOT_NAME} version #{BOT_VERSION}"
$log.puts "(C) 2012 Blevintron"
$log.puts "This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt"
$log.puts

# Write a PID file
File.atomic_create PID_FILE do |pidout|
  pidout.puts Process.pid
end

# Make it easy to shut down from the terminal.
$cancel = false
trap "INT" do
  shutdown! if $cancel

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

$db = DB.load DB_DIR

# If we receive SIGUSR1, we will mark our entire database dirty
trap "USR1" do
  $log.puts
  $log.puts "****** Received SIGUSR1 ******"
  $log.puts "I will mark the database as dirty."
  $log.puts "****** Received SIGUSR1 ******"
  $log.puts
  $log.flush

  $db.dirty!
end

def shutdown!
  $db.print_scrape_stats
  $db.print_edit_stats
  File.delete PID_FILE
  $log.puts "Shutdown: #{Time.now}"
  $log.flush
end

$db.upload_source_code!

edits_allowed = true
until $cancel

  $db.print_scrape_stats
  $db.print_edit_stats

  # Keep CPU, Network utilization low
  $db.wait
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

  # Find more links
  $db.scrape!

  # Check link quality
  $db.check_links!

  # Perform editing
  if edits_allowed
    $db.perform_edits!
  end

  # Check if my changes were reverted,
  # and maybe do something about that.
  $db.check_previous_edits!

  # Upload my stats
  $db.upload_stats!

  # Save the database to persistent storage
  $db.save DB_DIR
end

shutdown!

