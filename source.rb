
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: upload source code to wikipedia

require 'api'

class DB

  def upload_source_code!
    return unless should_upload_source_code?

    do_upload_source_code @lastSourceCodeUpload

    stats_dirty!
    @lastSourceCodeUpload = Time.now
  end

private
  def should_upload_source_code?
    # This task discouraged.  [[Wikipedia:NOTWEBSPACE]]
    return false if MIN_SOURCE_CODE_UPLOAD_PERIOD == nil
    (Time.now - @lastSourceCodeUpload) >= MIN_SOURCE_CODE_UPLOAD_PERIOD
  end
end

def sourcefile2article filename
  "#{SOURCE_CODE_BASE}/#{filename}"
end

# Wiki markup to escape various source codes.
FENCES = { '.rb'  => ['<syntaxhighlight lang="ruby">', '</syntax'+'highlight>'] }
DEFAULT_FENCE = ['<pre>', '</pre>']

def open_fence ext
  (FENCES[ext] || DEFAULT_FENCE).first
end

def close_fence ext
  (FENCES[ext] || DEFAULT_FENCE).last
end



def do_upload_source_code newerthan=nil
  table_of_contents = ''
  table_of_contents << "This is the source code for #{BOT_NAME} version #{BOT_VERSION}.\n"
  table_of_contents << "Do not modify this page; it is automatically overwritten every time the bot starts up.\n\n"

  articles = []

  table_of_contents << "{| class=\"wikitable\"\n"
  table_of_contents << "|-\n! File name\n! Description\n! Last Modification\n"

  SOURCE_CODE_EXTENSIONS.each do |extension|
    Dir[ SOURCE_CODE_DIR + '/*' + extension ].sort.each do |filename|
      basename = File.basename filename
      article = sourcefile2article basename
      description,text = prepare_source_file filename, extension

      mtime = (File.stat filename).mtime
      table_of_contents << "|-\n| [[#{article} | #{basename}]]\n| #{description}\n| #{mtime.getutc.strftime "%F" }\n"

      if newerthan == nil or mtime > newerthan
        articles << [article, text]
      end
    end
  end
  table_of_contents << "|}\n"

  articles << [ SOURCE_CODE_BASE, table_of_contents ]

  # Now upload those files.
  Api.session( BOT_USERNAME, BOT_PASSWORD ) do |session|
    articles.each do |title, body|
      $log.puts "Uploading #{title}..."
      result, revid = session.replace title, nil, "Update to current source code", body
      $log.puts " -> #{result}"
    end
  end
end

def prepare_source_file filename, ext
  description = ''
  body = ''

  body << "This file is part of [[#{SOURCE_CODE_BASE} | the source code for #{BOT_NAME}]] version #{BOT_VERSION}. "
  body << "Do not modify this page; it is automatically overwritten every time the bot starts up.\n\n"

  body << "This page contains the source file #{File.basename filename}.\n\n"

  body << (open_fence ext)

  File.open(filename, 'r').each_line do |line|
    # Censor BOT_USERNAME, BOT_PASSWORD, OPERATOR_USERNAME

    # Censor the definitions, and force users to configure the
    # BOT before running.
    if line =~ /^\s*BOT_USERNAME\s*=/
      line = "BOT_USERNAME = (raise 'You must specify BOT_USERNAME')\n"

    elsif line =~ /^\s*OPERATOR_USERNAME\s*=/
      line = "OPERATOR_USERNAME = (raise 'You must specify OPERATOR_USERNAME')\n"

    elsif line =~ /^\s*BOT_PASSWORD\s*=/
      line = "BOT_PASSWORD = (raise 'You must specify BOT_PASSWORD')\n"
    end

    # Just in case.
    line.gsub! BOT_PASSWORD, '***CENSORED***'

    if line =~ /^\s*##\s*Description:\s*(.*)$/i
      description << $1.strip << ' '
    end

    body << line
  end

  body << (close_fence ext)

  [description,body]
end




