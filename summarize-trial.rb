#!/usr/bin/ruby -w


## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: utility to summarize all edits from recent trial into
## Description: a single, concise diff page.

require 'db'

newer_than = 0
newer_than = ARGV[0].to_i unless ARGV.empty?

editor = Editor.load DB_DIR

summaries = ''
article = ''

reconnect INSECURE_API_URL do |http|
  editor.summarize_recent_edits(newer_than, summaries, http)
  $log.puts "Summary is #{summaries.size / 1024} KB"

  File.atomic_create('summaries.out') do |fout|
    fout.puts summaries
  end

  # Select a title
  i = 1
  while true
    article ="User:#{OPERATOR_USERNAME}/MostRecentTrial"
    if i > 1
      article << i.to_s
    end

    # Is that page already there?
    hist = retrieve_history article,http,nil,nil,1
    break if hist.empty?

    $log.puts "Name #{article} is already taken..."
    i += 1
  end
end

puts "Uploading summary to '#{article}'"

Api.session( BOT_USERNAME, BOT_PASSWORD ) do |session|
  result,id = session.replace(
    article,
    nil,
    "Summary of most recent trial",
    summaries)

  puts "Result: #{result}"
end

