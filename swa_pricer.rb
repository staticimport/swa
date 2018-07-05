#!/usr/bin/env ruby

require 'mail'
require 'mechanize'
require 'socket'
require 'twilio-ruby' 

def init_logger()
  file = File.new("#{File::basename($PROGRAM_NAME).split('.')[0]}.log", "a")
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
    return "#{departure} => #{arrival}"
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
  def time_to_bucket_key(time)
    minutes = minutes_since_midnight(time)
    if minutes < 6 * 60
      return :early
    elsif minutes < 12 * 60
      return :morning
    elsif minutes < 18 * 60
      return :afternoon
    else
      return :evening
    end
  end
  def aggregated_bests
    prices = TripLegPrices.new
    @key_to_best.values.each do |r|
      bucket_key = time_to_bucket_key(r.departure)
      if prices.get(bucket_key) > r.price
        prices.set(bucket_key, r.price)
      end
    end
    return prices
  end
end

class TripLegPrices
  attr_accessor :prices
  def initialize
    @prices = { :early => Float::INFINITY, :morning => Float::INFINITY, :afternoon => Float::INFINITY, :evening => Float::INFINITY }
  end
  def has_any_prices
    @prices.each do |key,value|
      return true if value != Float::INFINITY
    end
    return false
  end
  def get(key)
    raise "Invalid key #{key}" if not [:early,:morning,:afternoon,:evening].include? key
    return @prices[key]
  end
  def set(key, value)
    raise "Invalid key #{key}" if not [:early,:morning,:afternoon,:evening].include? key
    @prices[key] = value
  end
  def update_with_return_text(new_prices)
    sms_text = ''
    @prices.each do |time,price|
      new_price = new_prices.get(time)
      if new_price < 0.85 * price
        sms_text += "#{time}: #{"%.2f" % price} => #{"%.2f" % new_price}\n"
      end
    end
    new_prices.prices.each do |time,new_price|
      set(time, new_price)
    end
    sms_text
  end
  def current_prices_str
    text = ''
    @prices.each do |time,price|
      if price != Float::INFINITY
        text += "#{time}: #{"%.2f" % price}\n"
      end
    end
    text
  end
end

class TripLeg
  attr_accessor :from, :to, :date, :short_date
  def initialize(from, to, date)
    @from       = from
    @to         = to
    @date       = date
    @short_date = @date.split('/')[0..1].join('/')
    @prices     = TripLegPrices.new
  end
  def update(new_prices)
    sms_text = @prices.update_with_return_text(new_prices)
    if sms_text == ''
      return ''
    else
      return "\nUPDATE #{@short_date} #{@from} => #{@to}\n#{sms_text}"
    end
  end
  def current_prices_str
    "CURRENT PRICES #{@short_date} #{@from} => #{@to}\n#{@prices.current_prices_str}"
  end
  def has_any_prices
    return @prices.has_any_prices
  end
end

class Trip
  attr_accessor :going_leg, :return_leg, :num_passengers
  def initialize(origin, dest, num_passengers, leave_date, return_date)
    @going_leg  = TripLeg.new(origin, dest, leave_date)
    @return_leg = TripLeg.new(dest, origin, return_date)
    @num_passengers = num_passengers
    @name = "#{@going_leg.short_date}-#{@return_leg.short_date} #{@going_leg.from} <=> #{@going_leg.to}"
  end
  def update(going_prices, return_prices)
    @going_leg.update(going_prices) + @return_leg.update(return_prices)
  end
  def to_s
    @name
  end
  def current_prices_str
    text = "----------- #{@name} -----------\n"
    [@going_leg,@return_leg].each do |leg|
      if leg.has_any_prices
        text += "#{leg.current_prices_str}\n"
      else
        text += "No prices for #{leg.short_date} #{leg.from} => #{leg.to}\n"
      end
    end
    return text
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
    raise "Duplicate key #{key}" if personals.include? key
    personals[key] = value
    LOG.info("set personals[#{key}] = #{personals[key]}")
  end
  return personals
end

def load_trips(filename)
  trips = []
  File.read(filename).split("\n").each do |line|
    line.chomp!
    next if line.length == 0 or line[0] == '#'
    split = line.split(':')
    raise "Expected origin:dest:num_passengers:01/01/2000:12/31/2001, not '#{line}'" if split.length != 5
    trips.push(Trip.new(split[0], split[1], split[2].to_s, split[3], split[4]))
  end
  return trips
end

def send_sms_if_enabled(body, personals)
  return if personals['sms.enabled'] != 'true'

	# set up a client to talk to the Twilio REST API 
  begin
	@client = Twilio::REST::Client.new(personals['sms.twilio_account_sid'], personals['sms.twilio_auth_token'])
 
	@client.account.messages.create({
  	:from => personals['sms.from'],
  	:to   => personals['sms.to'],
    :body => body
	})
  rescue Exception => e
    puts e
  end
  LOG.info("SMS sent!")
end

def setup_mail(personals)
  return if personals['email.enabled'] != 'true'
  options = { :address              => personals['email.smtp'],
              :port                 => personals['email.port'].to_i,
              :domain               => Socket.gethostname,
              :user_name            => personals['email.username'],
              :password             => personals['email.password'],
              :authentication       => 'plain',
              :enable_starttls_auto => true }
  Mail.defaults do
    delivery_method :smtp, options
  end
  LOG.info("mail setup!")
end

def send_email_if_enabled(subject, body_text, personals)
  return if personals['email.enabled'] != 'true'
  
  10.times do 
    begin
      Mail.deliver do
        from      'mymailbot69@gmail.com'
        to        personals['email.to'].split(',')
        subject   subject
        body      body_text
      end
      break
    rescue
      LOG.info("Mail failed, waiting and possibly trying again: " + e)
      sleep(60)
    end
  end
  LOG.info("mail sent!")
end

def send_it(subject, body, personals)
  send_sms_if_enabled(body, personals)
  send_email_if_enabled(subject, body, personals)
end

# args
raise "USAGE: #{$PROGRAM_NAME} <personals.txt> <trips.txt>" unless ARGV.length == 2
personals = load_personals(ARGV[0])
trips     = load_trips(ARGV[1])
setup_mail(personals)

last_summary_time = nil
while(true)
  LOG.info("scraping...")
  trips.each do |trip|
    begin
      agent = Mechanize.new
      agent.user_agent_alias = 'Windows Chrome'
      page = agent.get('https://www.southwest.com')
      form = page.form_with(:name => 'homepage-booking-form-air')

      form['originAirport']         = trip.going_leg.from
      form['destinationAirport']    = trip.going_leg.to
      form['returnAirport']         = '' #trip.return_leg.to
      form['outboundDateString']    = trip.going_leg.date
      form['returnDateString']      = trip.return_leg.date
      form['adultPassengerCount']   = trip.num_passengers.to_s
      form['seniorPassengerCount']  = '0'

      #puts 'here'
      puts form.buttons.size
      #div1 = form.div_with(:class => "booking-form--bottom-options-right-absolute")
      #puts div1
      #submit_button = form.button_with(:name => 'submitButton')
      #submit_button = form.button_with(:id => 'jb-booking-form-submit-button')
      submit_button = form.buttons[0]
      results_page = agent.submit(form, submit_button)
      results_form = results_page.form_with(:name => 'searchResults')
      puts 'there'

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

      going_prices  = outs.aggregated_bests
      return_prices =  ins.aggregated_bests
      send_text = trip.update(going_prices, return_prices)
      if send_text != '' and last_summary_time != nil
        send_text.split("\n").each { |line| LOG.info(line.chomp) }
        send_it("PRICE UPDATE: #{trip}", send_text, personals)
      else
        LOG.info("no change for #{trip}")
      end
    rescue Exception => e
      LOG.error("failed to fetch details for #{trip}: #{e}")
    end
  end

  # need to send a summary?
  if last_summary_time == nil or (Time.now - last_summary_time) / 60 / 60 >= 24
    LOG.info("sending summary email")
    text = "This email is simply list of current prices and an indication that this script is still running. " +
           "Prices are checked frequently and you will be alerted in a separate email whenever significant " +
           "price drops are noticed.\n\n"
    trips.each do |trip|
      text += trip.current_prices_str + "\n\n"
    end
    send_it("Current Prices of Your Upcoming SWA Flights", text, personals)
    last_summary_time = Time.now
  end

  # sleep random interval as not to appear scripted
  sleep_seconds = 60 + rand(120)
  LOG.info("will sleep for #{sleep_seconds} seconds until next scrape")
  sleep(sleep_seconds)
end

