
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

ALL_LANGUAGE_CODES = [
  'ab','ak','als','am','ar','arc','as','av','az','bg','bh','bi','bm','bn',
  'bpy','br','bs','bxr','ca','ce','ceb','cho','co','cr','cs','cu','cv','cy',
  'da','de','diq','ee','el','eo','es','et','eu','fa','ff','fi','fiu-vro',
  'fj','fr','frp','frr','fy','ga','gl','gn','gv','ha','hak','he','hi','hr',
  'hsb','ht','hu','hy','ia','id','ii','io','is','it','ja','ka','kab','kg',
  'ki','km','ko','ks','ksh','kv','la','lad','lb','lbe','lez','lg','li','lij',
  'lmo','lo','lt','lv','map-bms','mi','mk','ml','mr','ms','mt','my','mzn',
  'nah','ne','new','nl','nn','no','nov','nrm','nv','ny','om','os','pag',
  'pap','pcd','pdc','pi','pih','pl','pms','pnt','ps','pt','qu','rmy','ro',
  'roa-rup','roa-tara','ru','sah','sd','se','sg','sh','si','simple','sk',
  'sl','sm','sn','so','sq','sr','ss','st','stq','sv','sw','szl','te','tet',
  'tg','th','ti','tk','tl','to','tr','tt','tum','tw','udm','ug','uk','ur',
  'uz','ve','vec','vi','vls','vo','war','wuu','xal','xmf','yi','yo','za',
  'zh','zh-classical','zh-min-nan','zh-yue','zu']

