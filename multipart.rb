## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: adds 'multipart/form-data' encoding to Net::HTTP::Post

require 'net/http'

# 8000 is recommended by https://www.mediawiki.org/wiki/API:Edit#Large_texts
MULTIPART_LIMIT = 8000

class Net::HTTP::Post
  # Select the appropriate encoding
  # depending upon the size of the post data.
  def set_post_data args
    if args.to_s.size > MULTIPART_LIMIT
      # multipart/form-data
      set_multipart_form_data args

    else
      # application/x-www-form-urlencoded
      set_form_data args
    end
  end

  # This is so simple to implement, I don't know why
  # it's not part of the standard library.
  def set_multipart_form_data args
    bndry = choose_boundary args
    self['Content-Type'] = "multipart/form-data; boundary=\"#{bndry}\""

    bout = ''
    args.each_pair do |k,v|
      bout << "\r\n--" << bndry << "\r\n"
      bout << "Content-Disposition: form-data; name=\"#{k}\"\r\n\r\n"
      bout << v
    end
    bout << "\r\n--" << bndry << "--\r\n"

    self.body = bout
    self['Content-Length'] = bout.size.to_s
  end

private
  def choose_boundary args
    # Choose a separator string that does not
    # appear in any of the keys/values
    lump = args.to_s

    while true
      boundary = "#{rand}#{rand}#{rand}"
      return boundary unless lump.include? boundary
    end
  end
end


