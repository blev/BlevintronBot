#!/usr/bin/ruby


## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: utility to clear the experiment statistics.

require 'db'

input_dir = DB_DIR
output_dir = DB_DIR

i=0
while i < ARGV.size
  case ARGV[i]
  when '-i'
    input_dir = ARGV[i+1]
    i += 2
  when '-o'
    output_dir = ARGV[i+1]
    i += 2
  else
    $stderr.puts "Usage: clear-experiment-stats.rb [-i inputdir] [-o outputdir]"
    exit
  end
end

db = Editor.load input_dir
db.clear_experiment_stats!
db.save output_dir

