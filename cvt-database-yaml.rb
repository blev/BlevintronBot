#!/usr/bin/ruby -w


## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: utility to convert the database (all or part) to .yaml format

require 'net/http'
require 'uri'

require 'db'

input_dir = DB_DIR
output_dir = DB_DIR
limit = 'r0123456789bSEp'

i=0
while i < ARGV.size
  case ARGV[i]
  when '-i'
    input_dir = ARGV[i+1]
    i += 2
  when '-o'
    output_dir = ARGV[i+1]
    i += 2
  when '-l'
    limit = ARGV[i+1]
    i += 2
  else
    $stderr.puts "Usage: cvt-database-yaml.rb [-i inputdir] [-o outputdir] [-l limitstring]"
    exit
  end
end

db = DB.load input_dir

db.robots_dirty! if limit.include? 'r'
db.scrape_dirty! if limit.include? 'S'
db.edit_dirty! if limit.include? 'E'
db.bad_links_dirty! if limit.include? 'b'
db.previous_edits_dirty! if limit.include? 'p'

for i in 0 ... NUM_FRAGMENTS
  if limit.include? i.to_s
    db.fragment_dirty! i
  end
end

# This will yield a runtime warning
SAVE_DB_FORMAT = '.yaml'
db.save output_dir

