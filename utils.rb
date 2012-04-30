
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description:  utility methods

require 'pp'
require 'uri'

class File

  # Create a file for writing.
  # All writes will appear atomically.
  def self.atomic_create(fn)
    tmpfile = fn + '.tmp'
    begin
      File.open(tmpfile, 'w') do |fout|
        yield fout
      end
      File.rename tmpfile, fn

    ensure
      if File.exist? tmpfile
        File.delete tmpfile
      end
    end
  end
end

class Dir
  # like mkdir -p
  def self.mkdir_p path
    components = []
    until path == '/'
      components.push path
      path = File.dirname path
    end
    until components.empty?
      dir = components.pop
      begin
        Dir.mkdir dir
      rescue Exception => e
        # directory already exists
      end
    end
  end
end

class Time
  def self.tomorrow
    Time.now + 1.days
  end

  def self.yesterday
    Time.now - 1.days
  end

  def morning
    # Set hour,minute,second == 0
    Time.local( year, month, day )
  end


  # Format as a string that mediawiki can swallow
  def mediawiki
    getutc.strftime "%Y%m%d%H%M%S"
  end

  # Informal day: today, yesterday, or DD Month
  def informal_recent
    today = Time.now.getutc.yday

    case getutc.yday
    when today
      return 'today'

    when today-1
      return 'yesterday'

    else
      return dm
    end
  end

  # Informal day: on 21 July, in July 2002...
  def informal_old
    if year == Time.now.year
      "on #{ dm }"
    else
      "in #{ my }"
    end
  end

  # Month Year
  def my
    getutc.strftime "%B %Y"
  end

  # DD Month Year
  def dmy
    u = getutc
    "#{u.day} #{u.strftime "%B %Y"}"
  end

  # DD Month
  def dm
    u = getutc
    "#{u.day} #{u.strftime "%B"}"
  end

  # Month DD, Year
  def mdy
    u = getutc
    "#{u.strftime "%B"} #{u.day}, #{u.year}"
  end

  # We set this if there is an
  # explicit indication of format,
  # e.g. {Use dmy dates}
  @@explicit_preferred_format = nil
  def self.explicit_preferred_format= s
    if s == 'mdy'
      @@explicit_preferred_format = 'mdy'
    else
      @@explicit_preferred_format = 'dmy'
    end
  end

  # We set this if there is a heuristic
  # reason to believe this is the
  # preferred format.
  @@implicit_preferred_format = nil
  def self.implicit_preferred_format= s
    if s == 'mdy'
      @@implicit_preferred_format = 'mdy'
    else
      @@implicit_preferred_format = 'dmy'
    end
  end

  # Decide which format is preferred.
  # Explicit declarations outweigh implicit ones
  def self.preferred_format
    @@explicit_preferred_format || @@implicit_preferred_format || 'dmy'
  end

  # Reset preferences (call before each article)
  def self.reset_format_preference!
    @@explicit_preferred_format = @@implicit_preferred_format = nil
  end

  # For the {{para|df}} of {{tl|Wayback}}
  def self.day_first?
    if Time.preferred_format == 'dmy'
      return 'yes'
    else
      return 'no'
    end
  end

  # Preferred date format, either dmy or mdy
  def wikitext_format
    if Time.preferred_format == 'mdy'
      return mdy
    else
      return dmy
    end
  end
end

def sleep_or_cancel n
  while n >= 1
    return if $cancel

    sleep 1
    n -= 1
  end
  sleep n
end

# A trick to track down which object failed to serialize.
class Object
  def test_marshal
    visited = {}
    res = test_marshal_rec visited
    unless res.empty?
      res.reverse!
      $log.puts "This object cannot be marshaled because:"
      res.each {|r| $log.puts "#{r}, "}
    end
  end

  # Sweep the data structure in DFS post-order, and try to Marshal.dump
  # every object.  If it fails, record an access path
  # to that object.
  def test_marshal_rec visited
    begin
      # Avoid infinite recursion on cyclic data
      return [] if visited.has_key? object_id
      visited[object_id] = true

      # Foreach field of this object
      tm_each_member do |fieldname, fieldvalue|

        # recur
        result = fieldvalue.test_marshal_rec visited
        unless result.empty?
          # record access path
          result.push fieldname.to_s
          return result
        end
      end

      # Try to marshall this object
      Marshal.dump self

    rescue Exception => e
      # Failed to marshal... why?
      result = []
      result.push self.pretty_inspect
      result.push(e.backtrace.join "\n")
      result.push e.to_s
      return result
    end

    return []
  end

  # This method provides access to 'members',
  # which by default means all instance variables.
  # We has special cases for Array, Hash, below
  def tm_each_member
    instance_variables.each do |fieldname|
      fieldvalue = eval fieldname
      yield [fieldname, fieldvalue]
    end
  end
end

# Special cases for Array, Hash.
class Array
  def tm_each_member
    each_index do |idx|
      yield [idx, self[idx]]
    end
  end
end

class Hash
  def tm_each_member
    each_pair do |k,v|
      yield ['key', k]
      yield [k, v]
    end
  end
end



class Statistic
  EPSILON = 1.0e-5

  def initialize
    @num = 0
    @sum = 0
    @sum2 = 0
    @min = nil
    @max = nil
  end

  def push v
    case v
    when nil  
      return

    when true
      w = 1.0

    when false
      w = 0.0

    else
      w = v.to_f
    end

    @num += 1
    @sum += w
    @sum2 += w*w

    if nil == @min or w < @min
      @min = w
    end

    if nil == @max or w > @max
      @max = w
    end
  end

  def << v
    push v
    self
  end

  attr_reader :num, :sum, :min, :max

  def avg
    return nil if @num == 0
    @sum / @num
  end

  def variance
    return nil if @num == 0
    # E[x**2] - E[x]**2
    @sum2/@num - avg*avg
  end

  def stddev
    Math.sqrt variance
  end

  def wikify(sout='')
    if @num == 0
      # No samples
      sout << '(no samples)'

    elsif @max - @min < EPSILON
      # Samples, but no variation.
      sout << "'''" << (sprintf "%.3f", avg) << "''', "
      sout << 'n=' << num.to_s

    else
      # All other cases.
      sout << "'''"      << (sprintf "%.3f", avg) << "''', "
      sout << "min="     << (sprintf "%.1f", min) << ', '
      sout << "max="     << (sprintf "%.1f", max) << ', '
      sout << "&sigma;=" << (sprintf "%.3f", stddev) << ', '
      sout << 'n='       << num.to_s
    end
    sout
  end
end

# I stole this idea from the rails community.
class Fixnum
  def seconds
    self
  end

  def minutes
    60*seconds
  end
  
  def hours
    60*minutes
  end

  def days
    24*hours
  end

  def weeks
    7*days
  end

  def months
    # approx
    4*weeks
  end

  def years
    365*days
  end
end


# Print the string to fout
# Try to wrap lines.
# TODO merge with TMux somewhow
def linewrap fout, str, width = DIFF_COLUMN_WRAP
  str.each_line do |line|
    while line.size >= width
      col = line.rindex(/\s+/, width)
      col ||= line.index(/\s+/, width)
      break if col == nil

      before = line[0 ... col]
      fout.puts before

      col2 = line.index(/\S/, col) || col
      line = line[ col2 .. -1]
    end
    fout.puts line
  end
end

class URI::HTTP
  # Shorthand format.  Implicity http, and pseudo-schemes for wikipedia.
  def pretty
    s = self.to_s
    s.sub!(/^http:\/\/#{WIKI_LANGUAGE_CODE}\.wikipedia\.org/, 'WP:')
    s.sub!(/^https:\/\/#{WIKI_LANGUAGE_CODE}\.wikipedia\.org/, 'WPS:')
    s.sub!(/^http:\/\//, '')
    s
  end
end

