## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: manipulate wiki text to correct problems.

require 'config'
require 'template-exceptions'

class Editor

  # Fix links in article 'name' with latest revision 'body'
  # Output:
  #   nil on error, or
  #   new_body - new article body
  #   message  - description of edit
  #   archived_links - list of links which were replaced by adding an archive copy
  #   nArchived - number of occurrences of a link that were archived.
  #   broken_links   - list of links which were fixed by adding {{dead link}}
  #   nBroken - number of occurences of a link that were marked {{dead link}}
  #   remaining_links- list of links which have at least one unfixed occurence.
  #   introductions  - the result of search_history for each of the urls.
  #   replacements   - the result of find_archive_urls for each of the urls.
  def fix_links name,body
    # We don't know which date format is preferred.
    Time.reset_format_preference!

    # Re-scrape the page to find CURRENT links
    urls = scrape_article body

    # Remove links from this article's record @bad
    # if those links no longer appear within the page,
    # or which we cannot fix.
    #   (note that cannot_be_fixed? will change over time)
    start_time = Time.now
    bad_links = []
    @bad[name].each do |bad_link|
      blu = bad_link.url

      if nil == (urls.index blu)
        $log.puts "  No longer contains bad link #{blu}"

      elsif bad_link.cannot_be_fixed?
        $log.puts "  I have no means to fix this kind of bad link"

      elsif bad_links.index {|link| link.url == blu}
        # Shouldn't happen, but I've seen it...
        $log.puts "  Repeated bad URL #{blu} in @bad!?"

      elsif bad_link.is_ready?
        # Mostly, this case let's me fix bugs without throwing away
        # the the data I have collected in the past.

        # This link has been sitting in the @bad pool for a while.
        # We've probably fixed bugs since it was added.
        # Let's do one last sanity check.
        $log.puts "Sanity check"
        bad_links_dirty!
        bad_link.check!

        if bad_link.cannot_be_fixed?
          $log.puts " -- Nice catch.  This link's badness was a bug"

        else
          $log.puts " -- yeah, it's definitely bad."
          bad_links << bad_link 
        end

      else
        bad_links << bad_link
      end

      return nil if $cancel
    end
    if bad_links.empty?
      $log.puts "  This article has no more problem links"
      bad_links_dirty!
      @bad.delete name
      return nil
    elsif bad_links.size < @bad[name].size
      bad_links_dirty!
      @bad[ name ] = bad_links
    end
    $log.puts "* Sanity checks took #{Time.now - start_time} seconds"

    # Determine if the document explicitly
    # declares a preferred date format.
    body.each_template do |tl|
      if tl.is_use_dmy_dates?
        $log.puts "EXPLICIT preferred date format: dmy"
        Time.explicit_preferred_format = 'dmy'
        break
      elsif tl.is_use_mdy_dates?
        $log.puts "EXPLICIT preferred date format: mdy"
        Time.explicit_preferred_format = 'mdy'
        break
      end
    end

    # Select those links we will fix
    if MAX_LINKS_PER_EDIT
      contributing_bad_links = bad_links.take MAX_LINKS_PER_EDIT

    else
      contributing_bad_links = bad_links.dup
    end

    # Lookup article history to determine when each link
    # was added to the article.
    broken_uris  = contributing_bad_links.map {|link| URI.liberal_parse link.url}
    introductions = search_history name, broken_uris
    # some error while retrieving history.
    return nil if introductions.empty?
    return nil if $cancel

    # Try to find an access date for every broken link
    need_archive = []
    default_access_dates = {}
    contributing_bad_links.each do |link|
      url = link.url

      # Find access date for this link
      access_date = infer_access_date body,url,introductions

      need_archive << [access_date, url]
      default_access_dates[url] = access_date
    end

    # Look-up archive URLs
    replacements = find_archive_urls need_archive
    return nil if $cancel

    # Try to fix each problem link
    new_body = body
    changes = []
    remaining_links = []
    archived_links = []
    broken_links = []
    total_archived = 0
    total_marked = 0
    total_unfixed = 0
    contributing_bad_links.each do |link|
      return nil if $cancel
      $log.puts "    This article contains problem link: #{link.url}"

      replacement = replacements[ link.url ] || [nil,nil]
      default_access_date = default_access_dates[ link.url ]

      old_body = new_body
      new_body,change,nArchived,nMarked,nUnfixed,fixed_all = fix_404 old_body, link, default_access_date, replacement

      changes << change

      archived_links  << link if nArchived>0
      broken_links    << link if nMarked>0
      remaining_links << link unless fixed_all

      total_archived += nArchived
      total_marked   += nMarked
      total_unfixed  += nUnfixed
    end

    message = changes.compact.join '; '

    # In case detailed message is too long...
    if message.size > 150
      message = ''
      if total_archived > 1
        message << "Add archive for dead links in #{total_archived} places"
      elsif total_archived == 1
        message << "Add archive for dead link"
      end

      if total_marked > 0
        message << "; " unless message == ''
        if total_marked > 1
          message << "Mark dead links in #{total_marked} places"
        elsif total_marked == 1
          message << "Mark dead link"
        end
      end
    end

    [new_body,message,archived_links,total_archived,broken_links,total_marked,remaining_links,total_unfixed,introductions,replacements]
  end

private

  # Try to determine the access date for a URL
  # based upon its context(s) in body and article
  # revision history.
  def infer_access_date body, url, introductions
    $log.print "Link '#{url}' - "

    body.each_url_occurrence url do |idx|
      next if is_unparsed? body,url,idx

      # Does this link appear in a {{cite *}} template that
      # declares the access date?
      if_within_template body,url,idx do |template|
        if template.is_citation?
          date = template.accessdate
          if date
            $log.puts "declared access date #{date.wikitext_format}"
            return date
          end
        end
      end

      # Does this link appear in a <ref> tag that
      # declares the access date?
      if_within_ref body,url,idx do |rb,re|
        ref = body[rb .. re]
        if ref =~ /(Retrieved|Retrieval\s+Date|Accessed|Access\s+Date)(\s+on)?:?(.*)/mi
          date = try_parse_date $3.strip
          if date
            $log.puts "informal-declared access date #{date.wikitext_format}"
            return date
          end
        end
      end
    end

    # In the worst case: infer access date from history 
    if introductions.has_key? url
      date = introductions[url][1]
      $log.puts "inferred access date #{date.wikitext_format}"
      return date
    end

    nil
  end

  # Inputs:
  #   old_body - previous article text
  #   bad_link - the Link object we want to repair
  #   default_access_date - If the context does not specify an access date,
  #     assume this access date
  #   replacement - [date,url] of the closest match from the archives.
  # Ouputs:
  #   new_body  - new article text
  #   change    - a text description of the change
  #   archived  - int - number of occurrence with an archive copy
  #   broken    - int - number of occurrence marked with {{broken link}}
  #   unfixed   - int - number of occurrences NOT FIXED.
  #   fixed_all - boolean - did we fix all occurrences of the link.
  def fix_404 body, link, default_access_date, replacement
    oldurlstr = link.url
    repl_date = replacement[0]
    repl_url  = replacement[1]

    $log.puts "      Trying to fix a 404 link"

    fixedAll = true
    markedDeadNumPlaces = 0
    markedArchiveNumPlaces = 0
    unfixedNumPlaces = 0

    body = body.dup

    body.each_url_occurrence oldurlstr do |idx|
      # We know that there is at least one occurrence of
      # oldurlstr in body that has not been marked dead.
      # However, there may be some occurrences which are
      # already marked dead (sandbox/test0).
      next if this_use_dead_or_archived? body,oldurlstr,idx

      # Cases:
      #         (position)               x   (replacement)
      #   (0) {{Cite *}} template        ; we have a replacement link.  => add archiveurl=,archivedate=
      #   (1) {{Cite *}} template        ; no replacement link.         => add {{Dead link}} after
      #   (2) Bare/bracket link in <ref> ; we have a replacement link   => change to {{Cite web...}
      #   (3) All other positions        ; we have a replacement link.  => add {{Wayback}}} or {{WebCite}} after
      #   (4) All other positions        ; no replacement link.         => add {{Dead link}} after

      # A citation template?
      fixed = false
      in_cite_template = false
      in_weird_template = false
      if_within_template body,oldurlstr,idx do |template|
        if template.is_citation?
          in_cite_template = true

          # Which link are we checking? The URL or the archive URL
          if template['url'] == oldurlstr
            accessdate = template.accessdate || default_access_date

            if suitable? accessdate,repl_date
              # Case (0) - A {{cite*}} template with a suitable replacement.

##            "Adding access date. There is no current obvious consensus to
##            do so, and I have asked about this on VP before: here and here.
##            Additionally [1] duplicates a manually written access date:
##            "Retrieved April 11, 2008."" - Hellknowz
##
##              if template['accessdate'] == nil
##                template['accessdate'] = accessdate.wikitext_format
##              end

              template['archiveurl'] = escape_citation_url repl_url
              template['archivedate'] = repl_date.wikitext_format

##            "Current bots don't add |deadurl=yes if the archive parameters
##            are set, because that is the default behavior already." - Hellknowz
##
##              template['deadurl'] = 'yes'
              if template['deadurl']
                # Simply removing the arg would be confusing in diffs.
                template['deadurl'] = 'yes'
              end

##            "Citation templates don't implement a |bot= parameter" - Hellknowz
##
##              template.bot!

              template.substitute_within! body
              markedArchiveNumPlaces += 1
              fixed = true

            else
              # Case (1) - A {{cite*}} template with NO suitable replacement.
              broken_link_tag.insert_after! body, template.end_offset+1
              markedDeadNumPlaces += 1
              fixed = true
            end
          end

        else
          $log.puts "        Link occurred in weird template #{template.name}"
          in_weird_template = true
        end
      end

      if (not fixed) and (not in_cite_template)
        # For some contexts, we need to move
        # the {{Dead link}} tag /after/ an enclosure.

        first = idx
        last  = idx + oldurlstr.size - 1

        # Don't place {{Dead link}} within a [bracket link]
        if_within_brackets body,oldurlstr,idx do |f,l|
          # put the {{Dead link}}, etc /after/ the bracket link.
          first,last = f,l
        end

        # A few templates are fussy.
        if_within_template body,oldurlstr,idx do |tag|
          # These templates require the tag after
          if TAG_AFTER_TEMPLATES.include? tag.name
            # put the {{Dead link}}, etc /after/ this template.
            first,last = tag.start_offset, tag.end_offset+1
          end
        end

        accessdate = default_access_date

        # Is this enclosed within a <ref> tag?
        if_within_ref body, body[first..last], first do |rb,re|

          # Is it the only external link within this <ref> tag?
          reftag = body[rb..re]
          links = extract_urls reftag

          if links.size == 1
            if suitable? accessdate,repl_date
              # Case (2)

  ##        [[WP:CITEVAR]] - should not be changing referenceing style.
  ##
  ##            t = Template.new 'Cite web'
  ##
  ##            # Generate a title if we don't have one already
  ##            unless link_title
  ##              link_title = "#{oldurlstr} <!-- bot generated title -->"
  ##            end
  ##
  ##            t['title'] = escape_citation_title link_title
  ##
  ##            t['url'] = escape_citation_url oldurlstr
  ##            t['accessdate'] = accessdate.wikitext_format
  ##
  ##            t['archiveurl'] = escape_citation_url repl_url
  ##            t['archivedate'] = repl_date.wikitext_format
  ##
  ##            t['deadurl'] = 'yes'
  ##
  ##            t.bot!
  ##
  ##            body[ first..last ] = t.to_s

              begin_close_ref = body.rindex '<', re
              archive_tag(repl_date,repl_url).insert_before! body, begin_close_ref

              markedArchiveNumPlaces += 1
              fixed = true
            end
          end
        end

        # (not in {{cite}}, not in <ref>)

        # All other cases:
        unless fixed
          # Make sure it's not within a boycott template.
          boycott = false
          if_within_template body,oldurlstr,idx do |tag|
            if BOYCOTT_TEMPLATES.has_key? tag.name
              bad_parms = BOYCOTT_TEMPLATES[ tag.name ]
              if bad_parms.empty?
                $log.puts "  BOYCOTT {{ #{tag.name} }}"
                boycott = true

              else
                bad_parms.each do |parm|
                  if tag[parm] and (tag[parm].include_url? oldurlstr)
                    $log.puts "  BOYCOTT {{ #{tag.name} | #{parm}= }}"
                    boycott = true
                    break
                  end
                end

              end
            end
          end

          unless boycott
            if suitable? accessdate, repl_date
              # Case (3) - All other positions, with suitable replacement
              archive_tag(repl_date,repl_url).insert_after! body, last
              markedArchiveNumPlaces += 1
              fixed = true

            else
              # Case (4) - All other positions, no suitable replacement
              broken_link_tag.insert_after! body, last
              markedDeadNumPlaces += 1
              fixed = true
            end
          end
        end
      end

      unless fixed
        # Why not?
        unfixedNumPlaces += 1
        fixedAll = false
        $log.puts "        This occurrence of #{oldurlstr} was not fixed."
      end
    end

    msg = ''
    if markedDeadNumPlaces > 0
      msg << "Mark dead link #{oldurlstr}"
      if markedDeadNumPlaces > 1
        msg << " in #{markedDeadNumPlaces} places"
      end
    end

    if markedArchiveNumPlaces > 0
      msg << " and " unless msg == ''

      msg << "Add archive for dead link #{oldurlstr}"
      if markedArchiveNumPlaces > 1
        msg << " in #{markedArchiveNumPlaces} places"
      end
    end

    [body, msg, markedArchiveNumPlaces, markedDeadNumPlaces, unfixedNumPlaces, fixedAll]
  end

  def archive_tag(date,url)

    # The two templates /really/ require different date formats :(
    u = URI.liberal_parse url
    if u.host == 'web.archive.org'
      # http://en.wikipedia.org/wiki/Template:Wayback
      t = Template.new 'Wayback'
      t['date'] = date.mediawiki
      # Disassemble the URL, so the template can re-assemble it :-/
      u2 = url.index('http', 1)
      t['url'] = url[ u2..-1 ]

      # The day-first parameter.
      t['df'] = Time.day_first?

    elsif u.host == 'webcitation.org'
      # http://en.wikipedia.org/wiki/Template:WebCite
      t = Template.new 'WebCite'
      t['date'] = date.wikitext_format
      t['url'] = url

      # Either mdy or dmy
      t['dateformat'] = Time.preferred_format

##    This template does not accept this parameter.
##      t['deadurl'] = 'yes'
    end

##  Neither {{WebCite}} nor {{Wayback}} accept the |bot= parameter
##    t.bot!
    t
  end

  def broken_link_tag
    # Template:Dead_link explicitly calls for 'Month Year'
    t = Template.new 'Dead link'
    t['date'] = Time.now.my
    t.bot!
    t
  end

  def escape_citation_title t
    link_title = t.dup

    # Escape sensitive chars in title, see [[Template:Cite web]]
    link_title.gsub! "\n", ' '
    link_title.gsub! '[', '&#91;'
    link_title.gsub! ']', '&#93;'
    link_title.gsub! '|', '&#124;'
    link_title
  end

  def escape_citation_url u
    # Escape sensitive chars in url, see [[Template:Cite web]]
    # TODO
    u
  end

end


