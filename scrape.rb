
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: code for scraping articles for links

require 'config'
require 'link'
require 'nobots'
require 'throttling'
require 'markup'
require 'rexml/document'
require 'yaml'
require 'utils'
require 'retrieve'

class Scraper

  def scrape!
    return unless should_scrape?

    # Search for more links in random articles
    articles = []
    begin

      # First, select some random articles to scrape.
      uri = SELECT_RANDOM_PAGE_URL
      reconnect(uri) do |http|

        if FAKE_SELECT
          # Use a hard-coded list of articles instead
          # of selecting randomly.
          $log.puts "(FAKE_SELECT) using hard-coded article list"
          articles = FAKE_SELECT.dup

        else
          # Select random articles from wikipedia
          $log.puts "Selecting random articles..."
          body,date = retrieve_page_maxlag uri, http

          # If max-lag,
          # then body==nil,
          # then articles=[],
          # then this function does nothing...

          if body
            xml = REXML::Document.new body
            xml.elements.each('/api/query/random/page') do |page|
              articles << (REXML::Text.unnormalize page.attribute('title').to_s)
            end
          end
        end

        if FAKE_SELECT_APPEND
          $log.puts "(FAKE_SELECT_APPEND) adding more articles"
          articles += FAKE_SELECT_APPEND
        end

        # Fetch each article
        articles.each do |article|
          body, revision = retrieve_article article, http
          next if body == nil

          begin
            if wiki_forbids_bots? body
              $log.puts "- This page excludes bots."
              next
            end

            # Scrape links from the article body
            urls = scrape_article body
            urls.each do |url|
              addLink article, url
            end

            # Statistics...
            @numArticlesVisited += 1
            @lastScrape = Time.now
            scrape_dirty!

          rescue Exception => e
            $log.puts "Exception while parsing article #{article}: #{e}"
          end
        end
      end

    rescue Exception => e
      $log.puts "Some exception during scrape: #{e}"
    end
  end


private

  def scrape_saturated?
    num_undecided >= max_undecided_links
  end

  def max_undecided_links
    [ MAX_LINKS_POOL, days_running * MAX_LINKS_PER_DAY].min
  end

  def days_running
    seconds_running= Time.now - @first_run_time
    (seconds_running/1.days).floor + 1
  end

  def scrape_throttled?
    Time.now - @lastScrape < scrape_period
  end

  def should_scrape?
    (not scrape_saturated?) and (not scrape_throttled?)
  end

  def next_scrape_time
    if scrape_saturated?
      return nil

    else
      t = @lastScrape + scrape_period

      if $maxlag_until
        t = [t, $maxlag_until].max
      end

      $log.puts "* Next scrape at #{t}"
      return t
    end
  end

  def addLink(article, uri)
    uristr = uri.to_s

    # Check if this link exists in any
    # of the fragments
    @fragments.each_index do |fragno|
      url2link = @fragments[ fragno ]
      if url2link.has_key? uristr
        url2link[ uristr ].add_user article
        fragment_dirty! fragno
        return
      end
    end

    # Otherwise, add a new link object
    link = Link.new uristr
    link.add_user article

    # add to front of schedule
    @link_schedule.unshift link

    # Insert it into the appropriate fragment
    @fragments[ link.fragno ][ uristr ] = link
    fragment_dirty! link.fragno
  end

  def num_undecided
    n = 0
    @fragments.each do |url2link|
      n += url2link.size
    end
    n
  end



end
