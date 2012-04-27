
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: advanced configuration options for expert users.

# ------------- Timeouts

# Whenever we need to pause for a short time, use this
EPSILON_WAIT = 5.seconds

# Waiting to be plugged into an AC adaptor
BATTERY_WAIT = 60.seconds

# Waiting for network to come online
NETWORK_WAIT = 60.seconds

# Upper bound on idle waits
MAX_IDLE_WAIT = 10.minutes

# -------------- Retry on error

# If an HTTP request fails, try again
MAX_HTTP_ATTEMPTS = 3

# Time-out before retrying a failed HTTP request
HTTP_RETRY_TIMEOUT = 1.seconds

# If a Mediawiki request fails, try again
MAX_API_ATTEMPTS = 6

# Time-out before retrying a rate-limited MediaWiki
# API request.  Probably should be less than
# 15 seconds, which is approx the keep-alive period.
API_RETRY_TIMEOUT = 12.seconds

# -------------- Link checking

# Each link must fail to load N times before we are
# willing to call it dead:
MIN_LINK_FAILURES = 3

# This is the minimum time between trials of a link
# - Check a link for failure no more frequently than
#   once every N seconds
LINK_TRIAL_PERIOD = 2.days

# Optionally, you may override the connect timeout
# used during link checking.
# Set this to nil if you do not want to override
OVERRIDE_HTTP_CONNECT_TIMEOUT = 45.seconds

# An eager strategy would check the first available
# link as soon as it is ready.
# Instead, we try to do large batches of link checks
# since larger batches are more likely to have several
# links from the same host, hence we have a higher
# probability of combining link checks into a single
# http connection. This parameter controls how long we
# are willing to wait if it will increase the size of
# a batch.
BATCH_LINK_WILLING_TO_WAIT = 60.seconds

# ------------- Throttling

# There are two reasons to throttle.
# (1) be nice to wikipedia servers
# (2) be nice to the wikipedia reviewers

# Throttling to be nice to the servers:

# Define a period of the day which is considered
# 'high-traffic.'  We will behave more slowly during
# the high-traffic period
HIGH_TRAFFIC_BEGIN=12 # UTC
HIGH_TRAFFIC_END=4 # UTC

# How quickly is this bot allowed to scrape pages from wikipedia?
# This bot will first request a list of randomly selected pages,
# and then download all of those pages.  We call this a 'scrape
# group'.  To be nice, we throttle our scrape groups.
# - at most one scrape group / N seconds during low traffic
LOW_TRAFFIC_SCRAPE_PERIOD = 10.seconds
# - at most one scrape group / N seconds during high traffic
HIGH_TRAFFIC_SCRAPE_PERIOD = 20.seconds

# How quickly is this bot allowed to make edits?
# - at most 1 edit / N seconds during low traffic
LOW_TRAFFIC_EDIT_PERIOD = 15.seconds
# - at most 1 edit / N seconds during high traffic
HIGH_TRAFFIC_EDIT_PERIOD = 30.seconds

# Maximum number of distinct links to correct
# in a single edit to a single article.
# This makes it easier for a human reviewer to
# look over the changes.  If nil, then do not
# bound the number of corrections to a single
# article edit.
MAX_LINKS_PER_EDIT = nil

# The minimum time that an article has been sitting
# in @bad before we will edit it
MIN_QUIESCENCE_PERIOD_ARTICLE = 1.hours

# The minimum time between edits to a single article
# (helps to avoid edit wars)
MIN_EDIT_PERIOD_PER_ARTICLE = 4.days

# The minimum time between messages to a single user.  So
# we don't annoy people.
MIN_SOLICIT_PERIOD_PER_USER = 1.weeks

# Maximum edits the bot will make during one calendar day.
# If nil, then no limit.
MAX_EDITS_PER_DAY = nil

# If we are in a trial period, they might specify
# a maximum number of edits.  Normally, this should be nil,
# meaning no limit
TRIAL_MAX_EDITS = 276 + 250

# if we are in a trial period, they might specify
# a maximum number of notifications.  Normally, this should
# be nil, meaning no limit.
TRIAL_MAX_NOTIFICATIONS = nil # 51

# --------------- Scraper

# The scraper task looks for questionable links and
# puts them into a pool.  The checker and fixer tasks
# will read from that pool, and potentially remove links
# from it.

# As a means of work balancing, the scraper will only
# search for more links if the pool has fewer than this
# many elements.  It will also try to do a soft-start,
# gradually increasing the limit by MAX_LINKS_PER_DAY until
# it reaches MAX_LINKS_POOL.
MAX_LINKS_PER_DAY = 2000
MAX_LINKS_POOL = 7 * MAX_LINKS_PER_DAY

# We accumulate a big pool of bad links.
# Some of those we can fix, some we cannot
# (we keep the ones we cannot, because we might
# be able to fix them in the future...)
# But, if this pool grows faster than we can
# edit them away, we should drop some too.
# These limits are numbers of /articles/
MAX_BAD_LINK_POOL = 10000
MIN_BAD_LINK_POOL =  5000

# -------------- /robots.txt cache

# How long should we cache the file robots.txt?
ROBOTSTXT_TTL = 1.days

# How many domains should we cache, at max
MAX_ROBOTSTXT_CACHE_SIZE = 3000 # hosts

# When evicting cache items, stop evicting if
# we get it down to this number.
MIN_ROBOTSTXT_CACHE_SIZE = (0.75 * MAX_ROBOTSTXT_CACHE_SIZE).to_i # hosts

# -------------- Persistent storage

# Database file format:
# choose either '.yaml' or '.marshal.gz'
# .yaml are human readable/editable, but are huge files and slow (300sec) to save
# .marshal.gz files are small and fast, but you can't debug them with a text editor.
SAVE_DB_FORMAT = '.marshal.gz'

# DON'T CHANGE THIS AFTER THE FIRST TIME YOU
# RUN THE BOT.
# Fragment the questionable links into
# this many parts.
NUM_FRAGMENTS = 6

# --------------- Editing
# --------------- Replacing links with archive copies

# If an archive copy is found, and that archive
# copy's archivedate is +/- N of the reported
# or inferred access date, then do not solicit
# the user, but instead add that archive link
# without confirmation.
MAX_DATE_ERROR_FOR_ARCHIVES = 6.months

# --------------- Local Edit Records

# When writing saving local records, wrap lines
# to make the diffs easier on the eyes.
# (this only applies to local files; we
# don't wrap lines while editing wikipedia)
DIFF_COLUMN_WRAP = 80

# --------------- Terminal multiplexor

TMUX_COLUMN_WRAP = 80

# -------------- Shutdown page

# A shutdown page.
# If this page matches /shutdown/i
# then the bot will stop.
SHUTDOWN_URL = URI.parse "http://#{WIKI_LANGUAGE_CODE}.wikipedia.org/wiki/User:#{BOT_USERNAME}/Bot/Shutdown?action=raw"

# --------------- Report status

# How often should we upload stats and experiment results
# - no more than once / n seconds.
MIN_STATS_UPLOAD_PERIOD = 1.days

# TODO
# Periodically save status here
STATUS_ARTICLE = "User:#{ BOT_USERNAME }/Bot/Status"

# ---------------- The solicitation-effectiveness experiment.

# To evaluate the effectiveness of the bot, it keeps separate
# statistics for each of these cases.
#   (0) -E-S -- Make no edits and send no solicitations;
#   (1) +E-S -- Make edits, but do not send solicitations;
#   (2) -E+S -- Send solicitations, but do not make edits;
#   (3) +E+S -- Make edits and send solicitations.
# If you set this option, the bot will select these cases
# with equal probabilities at edit time.  Otherwise, it
# will always select +E+S
EFFECTIVENESS_EXPERIMENT = false

# Track our edits to see if any of them has been reverted
# within this timeframe.
# Note that this determines how long we maintain a
# record of previous edits; we forget them after that.
CHECK_FOR_REVERTS_TIMEFRAME = 1.weeks

# Save experiment results here
EXPERIMENT_ARTICLE = "User:#{ BOT_USERNAME }/Bot/Experiment"
RAW_DATA_ARTICLE = "User:#{ BOT_USERNAME }/Bot/Experiment/RawData"

# -------------- Identity

# Contact info
CONTACT_ADDRESS = "http://#{WIKI_LANGUAGE_CODE}.wikipedia.org/wiki/User_talk:#{ OPERATOR_USERNAME }"

# User-agent strings
# This is the one we report to wikipedia
HONEST_USER_AGENT = "#{BOT_NAME} version #{BOT_VERSION} contact #{CONTACT_ADDRESS}"

# This is the one we tell other sites, so they think we're
# a real web browser.
PUBLIC_USER_AGENT = "Mozilla/5.0 (X11; Linux i686 on x86_64; rv:10.0) Gecko/20100101 Firefox/10.0"

# --------------- Inactive user classification.

# We say a user is inactive if they have never made a contribution,
# or if their last contribution is older than this.
USER_INACTIVITY_THRESHOLD = 5.months

# --------------- Options to aid debugging

# Override the 'select random articles' feature with a hard
# coded list of articles.  If this option is nil, then select
# random articles as normal.  If this option is an array of
# strings, only scrape those articles, and do NOT ask wikipedia
# for random articles.
FAKE_SELECT = nil

# Forcibly add articles to the selection list.
# If this option is not nil, then append this list
# of titles to the randomly selected article list.
# This option does NOT prevent the bot from asking wikipedia
# for random articles.
FAKE_SELECT_APPEND = nil

# Limit the users to whom we will send User_talk: messages.
# If this option is nil, then the bot is free to contact
# any user (subject to bot exclusions, of course).  If this
# option is an array of strings, then
# the bot will only send User_talk: messages to those listed
# here
LIMIT_CONTACT_USERTALK = nil

# If set, never send messages to IP-address users
NEVER_CONTACT_IP_USERS = true

# Limit the pages that this bot will edit.
# If this option is nil, the bot will freely edit any article.
# If this option is an array of strings, the bot will only
# edit articles listed in the array.
LIMIT_EDIT_ARTICLES = nil

# --------------- Captchas

# The name of the application to display
# an image.  Must support png images.
IMAGE_VIEWER_APP = "eog"
# failing that, try 'display' (distributed with ImageMagick)


