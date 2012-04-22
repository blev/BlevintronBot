
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: bot configuration options and sanity checking.
## Description: you probably want to edit config-simple.rb instead.

require 'utils'

require 'config-simple'
require 'constants'
require 'config-advanced'

# Sanity check parameters here.  These checks are neither complete
# nor particularly aggressive.  They're intended to be just enough
# to avoid crashes and undefined behavior, though they're probably
# not sufficient even for that ;)

def assert str
  unless (eval str)
    $stderr.puts "Assertion failed: #{str}"
    exit
  end
end

assert "BOT_USERNAME != nil"
assert "BOT_USERNAME != ''"

assert "OPERATOR_USERNAME != nil"
assert "OPERATOR_USERNAME != ''"

assert "BOT_USERNAME != OPERATOR_USERNAME"

assert "BOT_PASSWORD != nil"
assert "BOT_PASSWORD != ''"

assert "EPSILON_WAIT > 0"
assert "LOW_TRAFFIC_SCRAPE_PERIOD > 0"
assert "LOW_TRAFFIC_EDIT_PERIOD > 0"

assert "HIGH_TRAFFIC_SCRAPE_PERIOD >= LOW_TRAFFIC_SCRAPE_PERIOD"
assert "HIGH_TRAFFIC_EDIT_PERIOD >= LOW_TRAFFIC_EDIT_PERIOD"

assert "MIN_EDIT_PERIOD_PER_ARTICLE >= 0"

assert "ROBOTSTXT_TTL >= 0"
assert "MAX_ROBOTSTXT_CACHE_SIZE >= MIN_ROBOTSTXT_CACHE_SIZE"
assert "MIN_ROBOTSTXT_CACHE_SIZE > 0"

assert "(SAVE_DB_FORMAT == '.yaml' or SAVE_DB_FORMAT == '.marshal.gz')"

assert "MIN_STATS_UPLOAD_PERIOD > 0"
assert "MIN_SOURCE_CODE_UPLOAD_PERIOD == nil or MIN_SOURCE_CODE_UPLOAD_PERIOD > 0"

assert "CHECK_FOR_REVERTS_TIMEFRAME >= MIN_EDIT_PERIOD_PER_ARTICLE"

assert "HONEST_USER_AGENT.downcase.include? BOT_NAME.downcase"

assert "MIN_LINK_FAILURES > 0"
assert "LINK_TRIAL_PERIOD > 0"

assert "MAX_EDITS_PER_DAY == nil or MAX_EDITS_PER_DAY > 0"
assert "MAX_LINKS_PER_EDIT == nil or MAX_LINKS_PER_EDIT > 0"
assert "MIN_SOLICIT_PERIOD_PER_USER > 0"
assert "MAX_LINKS_PER_DAY > 0"
assert "MAX_LINKS_POOL > 0"


