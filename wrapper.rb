#!/usr/bin/ruby

## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: wrapper around main driver program; restart if
## Description: the bot dies for some reason.

$cancel = false
trap("INT") { $cancel = true }

until $cancel
  fork { exec "./wiki-badlink-bot.rb" }
  Process.wait
  sleep 1
end

