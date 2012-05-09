#!/usr/bin/ruby -w

require 'db'

files = []

n = 0

# Each parameter specifies an article, as...
ARGV.each do |spec|
  # ...a directory containing text files...
  if File.directory? spec
    files += Dir[ "#{spec}/*.before" ]

  # ...a single filename...
  elsif File.readable? spec
    files << spec

  # ...or the name of an article on wikipedia
  else
    body,date = retrieve_article spec
    if body
      filename = "#{ ENV['TMPDIR'] || '/tmp' }/tmp#{n}.wikitext"
      n += 1

      File.atomic_create filename do |fout|
        $log.puts "Saving #{spec} => #{filename}"
        fout.puts body
      end

      files << filename
    end
  end
end

total_time_old = 0
total_time_new = 0
n = 0

files.sort.each do |file|
  corpus = File.read file

  begin
    t0 = Time.now
    u0 = old_extract_urls corpus
    t1 = Time.now
    u1 =     extract_urls corpus
    t2 = Time.now

    total_time_old += t1-t0
    total_time_new += t2-t1
    n += 1

    # Compute difference, twice
    d01 = [] # u0-u1
    u0.each do |u|
      unless u1.include? u
        d01 << u
      end
    end
    d10 = [] # u1-u0
    u1.each do |u|
      unless u0.include? u
        d10 << u
      end
    end

    next if d01.empty? and d10.empty?

    # Sort both, longest first
    d01.sort! {|a,b| b.size <=> a.size }
    d10.sort! {|a,b| b.size <=> a.size }

    # Is an element of d01 a prefix of an element of d10
    appends = []
    d01.each do |old|
      found_one = false

      while true
        idx_new = d10.index {|u| u.start_with? old }
        break if idx_new == nil

        found_one = true
        new = d10[idx_new]

        d10.delete new
        appends << [old, new[old.size .. -1]]
      end
    end
    appends.each do |d,s|
      d01.delete d
    end

    $log.puts "Differences in #{file}"

    unless d01.empty?
      $log.puts "Old method found:"
      d01.each do |u|
        $log.puts "- '#{u}'"
      end
    end

    unless d10.empty?
      $log.puts "New method found:"
      d10.each do |u|
        $log.puts "- '#{u}'"
      end
    end

    unless appends.empty?
      max_p = appends.map {|prefix,suffix| prefix.size}.max

      $log.puts "Appends:"
      appends.each do |prefix,suffix|
        spaces = ' ' * (max_p - prefix.size)
        $log.puts "- #{spaces}'#{prefix}' + '#{suffix}'"
      end
    end

  rescue Exception => e
    $log.puts "Exception while extracting from file #{file}"
    exit
  end
end

$log.puts "Old #{ total_time_old.to_f / n } s"
$log.puts "New #{ total_time_new.to_f / n } s"
