
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: non-configurable constants


require 'uri'

# Bot name
BOT_NAME = BOT_USERNAME #"BrokenLinkBot"

# Articles
WIKI_NAMESPACE = 0

# Location of the api
API_ROOT = "#{WIKI_LANGUAGE_CODE}.wikipedia.org/w/api.php"

INSECURE_API_URL_STRING = "http://" + API_ROOT
INSECURE_API_URL = URI.parse INSECURE_API_URL_STRING

SECURE_API_URL_STRING = "https://" + API_ROOT
SECURE_API_URL = URI.parse SECURE_API_URL_STRING


# API call to retrieve a random list of pages
SELECT_RANDOM_PAGE_URL_STRING = "#{INSECURE_API_URL_STRING}?action=query&list=random&rnlimit=10&format=xml&rnnamespace=#{WIKI_NAMESPACE}"
SELECT_RANDOM_PAGE_URL = URI.parse SELECT_RANDOM_PAGE_URL_STRING

# Directory which contains source code. (absolute path)
SOURCE_CODE_DIR = Dir.chdir(File.dirname __FILE__) { Dir.pwd }

# Version number
# == timestamp of most recent source file
BOT_VERSION = Dir[SOURCE_CODE_DIR + '/*.rb'].map {|filename| (File.stat filename).mtime }.max.strftime "%F"

