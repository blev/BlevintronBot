## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: parsing/manipulating wikipedia templates

class String
  # Find each {{template}} within this string, and yield it.
  # When templates are nested, visit inner-templates before outer templates.
  # Returns a copy of the string with all templates redacted
  #
  # Not very efficient, which is not important since we're network bound.
  def each_template limits={}
    # Optionally, limit which templates we will yield.
    must_start_before = limits[:must_start_before]
    must_end_after    = limits[:must_end_after]
    must_start_after  = limits[:must_start_after]
    redact_nested     = limits[:redact_nested]

    scratch = self.dup

    # First, remove all unparsed markup from scratch.
    remove_unparsed! scratch

    prev_first = prev_last = nil

    while true
      # Redact the template found during the previous iteration
      # (important to do this here, so that 'next' and 'break'
      # work correctly within the block).
      if prev_first
        len = prev_last - prev_first + 2
        blanks = ' ' * len
        scratch[ prev_first .. prev_last+1 ] = blanks
        prev_first = prev_last = nil
      end

      first = scratch.index '{{'
      break if first == nil

      last = scratch.index('}}', first+2)
      break if last == nil

      # There are no '}}' between first and last
      # But there might be '{{'
      first = scratch.rindex('{{', last)

      # We remember these offsets so we can remove
      # the template from the 'scratch' string
      # after this iteration.
      prev_first = first
      prev_last = last

      next unless block_given?
      next if must_start_before and not (first <= must_start_before)
      next if must_end_after    and not (must_end_after <= last)
      next if must_start_after  and not (must_start_after <= first)
#      next if is_unparsed? self,blanks,first

      # Parse the template from the /original/ string
      if redact_nested
        tem = Template.parse scratch, first, last, scratch
      else
        tem = Template.parse self, first, last, scratch
      end

      yield tem
    end

    # Redact template found during final iteration
    if prev_first
      len = prev_last - prev_first + 2
      blanks = ' ' * len
      scratch[ prev_first .. prev_last+1 ] = blanks
    end

    scratch
  end

  alias redact_all_templates each_template

end



# Represents a {{template}} found in an article body.
# Care is taken so that updates will cause minimal diffs
# (e.g. capitalization, order of parameters, etc)
class Template
  attr_accessor :start_offset, :end_offset
  attr_accessor :source

  def initialize(tname = nil)
    @start_offset = nil
    @end_offset = nil
    @name = tname

    # We represent the parameters as a list of pairs
    # instead of a hash.  This allows to_s to generate
    # a minimal change...
    @params = []
  end

  def self.parse body, first, last, body_with_nested_templates_redacted = nil
    str = body[ first .. last+1 ]

    return nil unless str.start_with? '{{'
    return nil unless str.end_with? '}}'

    contents = str[2 .. -3]

    if body_with_nested_templates_redacted
      contents_skeleton = body_with_nested_templates_redacted[ first+2 .. last-1 ]
    else
      contents_skeleton = contents.redact_all_templates
    end

    # Tokenize.
    # Note that nested templates might have '|'
    # so we can't simply use split.
    tokens = []
    idx = -1
    while true
      prev_idx = idx+1
      idx = contents_skeleton.index '|', prev_idx

      if idx
        tokens << contents[ prev_idx ... idx ]

      else
        tokens << contents[ prev_idx .. -1 ]
        break
      end
    end

    template = Template.new
    template.start_offset = first
    template.end_offset = last
    template.source = str

    # Extract name
    template.name = tokens.shift

#    $log.puts "Parsing template {{#{template.name} ..."
    # Break up the parameters into a hash.
    tokens.each do |token|
      if token.strip == ''
        template.add_blank token
        next
      end

      # Does this param include an '=' sign?
      eqindx = token.index '='
      if eqindx == nil
        key = token
#        $log.puts " | #{key.strip}"
        template.add_param key

      else
        key = token[0 ... eqindx]
        value = token[eqindx+1 .. -1]

#        $log.puts " | #{key.strip} = #{value.strip}"
        template.add_param key,value
      end
    end
#    $log.puts "}}"

    template
  end

  def param_list
    @params.map {|k,v| k.canon }
  end

  def each_param(key = nil)
    # Some editors do invalid things like this:
    #   {{bots|deny=DPL bot|deny=MadmanBot|deny=CorenSearchBot|deny=BlevintronBot}}
    # Technically, only the last instance of deny= matters.  But, to match
    # user expectation, we need to be able to query ALL instances of deny=
    @params.each do |k,v|
      if (key==nil) or (k.canon == key.canon)
        if v
          yield [k.canon,v.strip]
        else
          yield [k.canon,nil]
        end
      end
    end
  end

  def each_param_non_canon
    @params.each do |k,v|
      yield [k,v]
    end
  end

  def name=(s)
    @name = s
  end

  def name
    n = @name.canon
    remove_unparsed! n
    n.strip
  end

  def is_citation?
    (name == 'citation') or (name.start_with? 'cite ') or (name.start_with? 'vcite ')
  end

  def is_archive?
    name == 'wayback' or name == 'webcite'
  end

  def is_dead?
    ['dead link', 'broken link', 'dead', 'dl', '404', 'nris dead link'].include? name
  end

  def is_use_dmy_dates?
    ['use dmy dates', 'dmy'].include? name
  end

  def is_use_mdy_dates?
    ['use mdy dates', 'mdy'].include? name
  end

  def accessdate
    try_parse_date self['accessdate']
  end

  def archivedate
    try_parse_date self['archivedate']
  end

  def bot!
    self['bot'] = BOT_NAME
  end

  def delete_param key
    @params.delete_if {|k,v| key.canon == k.canon}
    nil
  end

  def []( key )
    case key
    when String
      return get_named_param key
    when Fixnum
      return get_unnamed_param key
    end
    nil
  end

  def []=( key, value )
    case key
    when String
      set_named_param key,value
    when Fixnum
      set_unnamed_param key,value
    end
    value
  end


  def get_named_param key
    # According to Help:Template#Full_syntax_for_transcluding_and_substituting,
    # only the last instance of a parameter means anything.
    idx = @params.size-1
    while idx >= 0
      k,v = @params[idx]
      if key.canon == k.canon
        if v
          return v.strip
        else
          return nil
        end
      end
      idx -= 1
    end
    nil
  end

  def get_unnamed_param key
    ordinal = 1
    @params.each do |k,v|
      if v == nil
        # This is an unnamed param
        return k.strip if key == ordinal
        ordinal += 1
      end
    end
    nil
  end

  def set_named_param key,value
    # According to Help:Template#Full_syntax_for_transcluding_and_substituting,
    # only the '''last''' instance of a parameter means anything.

    # An update either substitutes a parameter, or adds a new one.
    # keys are kept IN ORDER to minimize the size of diffs

    new_params = []
    madeSubstitution = false
    @params.reverse.each do |k,v|
      if key.canon == k.canon
        prefix = suffix = ''
        if (v||'') =~ /^(\s*).*?(\s*)$/m
          prefix, suffix = $1, $2
        end

        # Substitute!
        new_params << [k,"#{prefix}#{value.strip}#{suffix}"]
        madeSubstitution = true

      else
        new_params << [k,v]
      end
    end
    new_params.reverse!

    unless madeSubstitution
      # Add new one

      # Guess layout convention.
      prefix = suffix = ''
      unless @params.empty?
        # take the first key=val as an model
        model_key, model_val = @params.first

        if model_key =~ /^(\s*)/m
          prefix = $1
        end

        model_val ||= model_key
        if model_val =~ /(\s*)$/m
          suffix = $1
        end
      end

      new_params << [ "#{prefix}#{key.strip}", "#{value.strip}#{suffix}" ]
    end

    @params = new_params

    value
  end

  def set_unnamed_param key,value
    throw "Not yet implemented"
  end

  def add_param key,value=nil
    @params << [key,value]
  end

  def add_blank token=''
    add_param token,nil
  end

  def to_s
    str = '{{'

    str << @name

    @params.each do |key, value|
      if value == nil
        str << "|#{key}"

      else
        str << "|#{key}=#{value}"
      end
    end

    str << '}}'
    str
  end

  def substitute_within body
    body[0 .. @start_offset-1] + to_s + body[@end_offset+2 .. -1]
  end

  def inspect
    s = "Template: #{name}\n"
    @params.each do |k,v|
      s << "    Key: '#{ (k||'').strip}'\n"
      s << "  Value: '#{ (v||'').strip}'\n"
      s << "\n"
    end
    s
  end

  def substitute_within! body
    body[ @start_offset .. @end_offset + 1 ] = to_s
  end

  def insert_after body, offset
    body[0 .. offset] + ' ' + to_s + body[offset+1 .. -1]
  end

  def insert_after! body, offset
    body.insert(offset+1, ' ' + to_s) 
  end

  def insert_before! body, offset
    body.insert(offset, ' ' + to_s)
  end

  def redact_from body
    len = @source.size
    body[0 .. @start_offset-1] + (' ' * len) + body[@end_offset+2 .. -1]
  end

  def redact_from! body
    len = @source.size
    body[ @start_offset, len ] = (' ' * len)
  end

end

