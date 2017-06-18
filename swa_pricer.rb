#!/usr/bin/env ruby

require 'mail'
require 'mechanize'
require 'pony'
require 'twilio-ruby' 

def init_logger()
  file = File.new("#{$PROGRAM_NAME}.log", "a")
  file.sync = true
  return Logger.new(file)
end
LOG = init_logger()
LOG.info('<<<<<<<< new run >>>>>>>>')

def minutes_since_midnight(time)
  hour,minute = time.split(' ')[0].split(':')
  total = hour.to_i * 60 + minute.to_i
  if time.include?('PM')
    total += 12 * 60
  end
  total
end

class Results
  def initialize(csv)
    @csv = csv
  end
  def arrival
    t = @csv[9]
    if t[1] == ':'
      t = '0' + t
    end
    t
  end
  def departure
    t = @csv[8]
    if t[1] == ':'
      t = '0' + t
    end
    t
  end
  def duration
    return @csv[4]
  end
  def key
    return "#{departure} -> #{arrival}"
  end
  def price
    split = @csv[2].split('@')
    return split[split.length - 2].to_f
  end
  def to_s
    return "#{key} (#{duration}): $#{price}"
  end
  def <=>(other)
    minutes_since_midnight(departure) <=> minutes_since_midnight(other.departure)
  end
end

class ResultSet
  def initialize
    @key_to_best = {}
    @overall_best = nil
  end
  def add(r)
    best = @key_to_best[r.key]
    if not best or best.price > r.price
      @key_to_best[r.key] = r
      if not @overall_best or @overall_best.price > r.price
          @overall_best = r
      end
    end
  end
  def best
    return @overall_best
  end
  def sorted
    @key_to_best.values.sort
  end
  def aggregated_bests
    minute_bucket_size = 6 * 60
    aggs = {}
    @key_to_best.values.each do |r|
      bucket = minutes_since_midnight(r.departure) / minute_bucket_size
      if aggs[bucket] == nil or aggs[bucket].price > r.price
        aggs[bucket] = r
      end
    end
    text = ''
    if aggs[0]
      text += "early:$#{aggs[0].price}  "
    end
    if aggs[1]
      text += "morning:$#{aggs[1].price}  "
    end
    if aggs[2]
      text += "afternoon:$#{aggs[2].price}  "
    end
    if aggs[3]
      text += "evening:$#{aggs[3].price}"
    end
    text
  end
end

def load_personals(filename)
  personals = {}
  File.read(filename).split("\n").each do |line|
    line.chomp!
    next if line.length == 0 or line[0] == '#'
    key,value = line.split("=")
    key.chomp!
    value.chomp!
    personals[:from]                = value if key == "from"
    personals[:to]                  = value if key == "to"
    personals[:twilio_account_sid]  = value if key == "twilio_account_sid"
    personals[:twilio_auth_token]   = value if key == "twilio_auth_token"
  end
  return personals
end

def load_trips(filename)
  trips = []
  File.read(filename).split("\n").each do |line|
    line.chomp!
    next if line.length == 0 or line[0] == '#'
    split = line.split(':')
    raise "Expected origin:dest:01/01/2000:12/31/2001, not '#{line}'" if split.length != 4
    trips.push({:origin => split[0], :dest => split[1], :leave => split[2], :return => split[3]})
  end
  return trips
end

def send_email(outbound_text, inbound_text)
  body = <<BODY_END
  OUTBOUND:
  #{outbound_text}

  INBOUND:
  #{inbound_text}
BODY_END

  Pony.mail({:to => 'bowles.craig@gmail.com', :from => 'who@cares.com', :subject => 'SWA Flight Alert!', :body => body, :via => :sendmail})
end

def send_sms(body, personals)
	# set up a client to talk to the Twilio REST API 
	@client = Twilio::REST::Client.new(personals[:twilio_account_sid], personals[:twilio_auth_token])
 
	@client.account.messages.create({
  	:from => personals[:from],
  	:to   => personals[:to],
    :body => body
	})
  LOG.info("SMS sent!")
end

# args
raise "USAGE: #{$PROGRAM_NAME} <personals.txt> <trips.txt>" unless ARGV.length == 2
personals = load_personals(ARGV[0])
trips     = load_trips(ARGV[1])

while(true)
  LOG.info("scraping...")
  trips.each do |trip|
    begin
      agent = Mechanize.new
      agent.user_agent_alias = 'Windows Chrome'
      page = agent.get('https://www.southwest.com')
      form = page.form_with(:name => 'homepage-booking-form-air')

      form['originAirport']         = trip[:origin]
      form['destinationAirport']    = trip[:dest]
      form['returnAirport']         = trip[:oriign]
      form['outboundDateString']    = trip[:leave]
      form['returnDateString']      = trip[:return]
      form['adultPassengerCount']   = '1'
      form['seniorPassengerCount']  = '0'

      submit_button = form.button_with(:name => 'submitButton')
      results_page = agent.submit(form, submit_button)

      results_form = results_page.form_with(:name => 'searchResults')

      outs = ResultSet.new
      ins  = ResultSet.new
      results_form.radiobuttons.each do |rb|
        r = Results.new(rb['value'].split(','))
        if rb['name'] == 'outboundTrip'
          outs.add(r)
        elsif rb['name'] == 'inboundTrip'
          ins.add(r)
        end
      end

      new_outbound_text = "OUT: " + outs.aggregated_bests
      new_inbound_text  = "IN:  " + ins.aggregated_bests
      new_text = "#{trip[:origin]}->#{trip[:dest]} on #{trip[:leave].split('/')[0..1].join('/')}: #{outs.aggregated_bests}" +
               "\n#{trip[:dest]}->#{trip[:origin]} on #{trip[:return].split('/')[0..1].join('/')}: #{ins.aggregated_bests}"
      if new_text != trip[:old_text]
        LOG.info("new prices for #{trip}!")
        new_text.split("\n").each { |line| LOG.info(line.chomp) }
        if trip[:old_text]
          send_sms(new_text, personals)
        end
      else
        LOG.info("no change for #{trip}")
      end
      trip[:old_text] = new_text
    rescue
      LOG.error("failed to fetch details for #{trip}")
    end
  end
  sleep_seconds = 60 + rand(120) # randomization not to appear scripted
  LOG.info("will sleep for #{sleep_seconds} seconds until next scrape")
  sleep(sleep_seconds)
end

