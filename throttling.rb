
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: limits on the rate of bot activity

require 'config'

def is_high_traffic_period?
  hour = Time.now.getutc.hour

  # Either the high-traffic interval spans midnight, or not.

  # Does not span midnight
  if HIGH_TRAFFIC_BEGIN < HIGH_TRAFFIC_END
    return (HIGH_TRAFFIC_BEGIN <= hour and hour <= HIGH_TRAFFIC_END)

  # Spans midnight
  else
    return (HIGH_TRAFFIC_BEGIN <= hour or hour <= HIGH_TRAFFIC_END)

  end
end

def scrape_period
  if is_high_traffic_period?
    return HIGH_TRAFFIC_SCRAPE_PERIOD

  else
    return LOW_TRAFFIC_SCRAPE_PERIOD

  end
end

def edit_period
  if is_high_traffic_period?
    return HIGH_TRAFFIC_EDIT_PERIOD

  else
    return LOW_TRAFFIC_EDIT_PERIOD

  end
end

def on_battery_power?
  begin
    ac_state = File.open('/proc/acpi/ac_adapter/AC/state').gets
    return ac_state !~ /on-line/i
  rescue
    # maybe we don't have an AC adaptor
  end

  false
end

def emergency_shutdown_check
  page,date = retrieve_page SHUTDOWN_URL

  if page == nil
    return :bad_network

  elsif page =~ /shutdown/i
    return :shutdown

  else
    return :good
  end
end


