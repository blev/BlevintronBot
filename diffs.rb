
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: compute diffs with in a context defined by wikitext
## Description: returns a string that can render as valid wikitext

require 'markup'

# Compare two wikitext document.
# Generate a diff that is a valid wikitext document.
def compute_diffs(original, modified, fout='')
  diff_occurrences = []

  # Assumption:
  # We neither insert nor delete lines, only modify lines
  # by replacing/inserting some text in the line.
  # This assumption works well for the kinds of edits
  # generated by this bot, but not for general edits.
  line_offset = 0
  org_lines = original.lines.to_a
  modified.each_line do |mod_line|
    org_line = org_lines.shift || ''

    # Line replaced?
    if org_line != mod_line

      # Find common prefix, suffix
      prefix_len = find_common_prefix(org_line,mod_line)
      suffix_len = find_common_suffix(org_line, mod_line)

      diff   = mod_line[ (prefix_len) ... (mod_line.size-suffix_len) ]
      diff_occurrences << [ line_offset + prefix_len,  diff ]
    end

    line_offset += mod_line.size
  end

  # Widen each change into a context
  contexts = []
  diff_occurrences.each do |offset,pattern|
    # By preference,
    #   - A <ref>...</ref> tag.
    #   - A template
    #   - A table row
    #   - The line itself.
    if_within_ref modified, pattern, offset do |first,close|
      contexts << [ first, close ]

    end or if_within_template modified, pattern, offset do |template|
      contexts << [ template.start_offset, template.end_offset+1 ]

    end or if_within_table_row modified, pattern, offset do |first,close|
      contexts << [ first, close ]

    end or begin
      begin_line = (modified.rindex("\n", offset) || -1)+1
      end_line = modified.index("\n", offset+pattern.size) || (modified.size-1)
      contexts << [ begin_line, end_line ]
    end
  end

  # Combine contexts if they overlap
  non_overlapping_contexts = []
  contexts.sort! {|a,b| a[0] <=> b[0]}
  until contexts.empty?
    head = contexts.shift
    while (not contexts.empty?) and head.last + 1 >= contexts.first.first
      head = [head.first, contexts.shift.last]
    end
    non_overlapping_contexts << head
  end

  # Assemble the contexts into a string
  non_overlapping_contexts.each do |start,close|
    ctx = modified[start..close]

    if ctx.start_with? "\n|-"
      # Wrap wiki-tables so they render correctly.
      fout << "{| class=\"wikitable\"" << ctx
      fout << "|}" unless ctx.include? "|}"
    else
      fout << ctx.strip
    end

    fout << "\n\n"
  end

  fout << "<references/>\n"
  fout
end

# Return the length of the common prefix
def find_common_prefix(s1, s2)
  shorter = [s1.size, s2.size].min
  i = 0
  while i < shorter
    break if s1[i] != s2[i]
    i += 1
  end
  i
end

# Return the length of the common suffix
def find_common_suffix(s1,s2)
  shorter = [s1.size, s2.size].min
  i=0
  while i < shorter
    break if s1[-(i+1)] != s2[-(i+1)]
    i += 1
  end
  i
end

