
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: basic configuration options for novice users.

# -------------- Which wikipedia language?

WIKI_LANGUAGE_CODE = 'en'

# -------------- Persistent storage

# Persistent database directory
DB_DIR = "#{ENV['HOME']}/.wikipedia-badlink-bot/"

# While running, store my process id in this file.
PID_FILE = "#{DB_DIR}/pid"
SCRAPER_PID_FILE = "#{DB_DIR}/pid.scraper"
EDITOR_PID_FILE = "#{DB_DIR}/pid.editor"

# Should I save a local record of edits?
# This information is wholly redundant with
# the contributions recorded by wikipedia, so
# this is probably a waste of disk space
# for everyone except the original author
# of the bot.
SAVE_EDITS_LOCALLY = true

# If so, save them to this directory.
EDITS_DIR = "#{DB_DIR}/edits/"

# If this is a filename, write all output
# to this file instead of stderr.
# If this is nil, write to stderr.
LOG_FILE = nil # "#{DB_DIR}/log-#{Time.now.strftime "%F"}"

# --------------- Logins

# This file should contain three lines:
# BOT_USERNAME = wikipedia username for the bot account.
# BOT_PASSWORD = password to the bot account.
# OPERATOR_USERNAME = wikipedia username for the bot's operator.
require "#{DB_DIR}/passwords.rb"

# --------------- Throttling
# to be nice to the wikipedia reviewers

# Do I dare edit wikipedia?
# If true, the bot will edit articles and send User_talk: messages.
# If false, the bot will still go through the motions, but
# will not modify anything outside of its User: space, which
# is useful for debugging in combination with SAVE_EDITS_LOCALLY.
ENABLE_EDITS_TO_LIVE_SITE = true

# --------------- Captchas

# This is useful /before/ the bot gets approval.
# Definitely not useful if you intend
# to run the bot as a background daemon.
#
# If wikipedia presents us with a captcha,
# we will download it an present it to the
# operator.  This determines how long we
# will wait for the user to respond to the
# challenge.  If zero, completely disable
# captcha handling---edits will always fail if
# challenged.  See also IMAGE_VIEWER_APP.
CAPTCHA_USER_TIMEOUT = 1.minutes


