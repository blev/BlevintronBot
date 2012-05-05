#!/usr/bin/ruby -w


## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: utility to summarize all edits from recent trial into
## Description: a single, concise diff page.

require 'db'

editor = Editor.load DB_DIR

summaries = editor.summarize_recent_edits
$log.puts "Summary is #{summaries.size / 1024} KB"

File.atomic_create('summaries.out') do |fout|
  fout.puts summaries
end

Api.session( BOT_USERNAME, BOT_PASSWORD ) do |session|
  puts "Uploading summary..."
  result,id = session.replace(
    "User:#{OPERATOR_USERNAME}/MostRecentTrial",
    nil,
    "Summary of most recent trial",
    summaries)

  puts "Result: #{result}"
end

