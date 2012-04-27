#!/usr/bin/ruby


## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: upload stats to wikipedia NOW instead of waiting for the right time.

require 'db'

db = Editor.load DB_DIR

db.do_upload_experiment

db.save DB_DIR

