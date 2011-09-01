require "rubygems"
require "twilio-ruby"
require "yaml"
require "sinatra"

$config = YAML::load(File.read("./config.yml"))

$validator = Twilio::Util::RequestValidator.new($config["twilio"]["token"])
$client = Twilio::REST::Client.new($config["twilio"]["sid"], $config["twilio"]["token"])

# General door handling
# Need to move this to a thread or unlink it from the initial Twilio response.
# Maybe use <Redirect>
def notify_arrival(data)
  return if data["mode"] == "none"
  $client.account.sms.messages.create(:from => $config["send_from"], :to => data["phone"], :body => data["message"])
end

def verify_call
  #unless $validator.validate(request.url, params, request.env["HTTP_X_TWILIO_SIGNATURE"])
  #  return (Twilio::TwiML::Response.new {|r| r.Say("We're sorry, your call could not be verified.")}).text
  #end

  unless params[:From] == $config["require_from"]
    return (Twilio::TwiML::Response.new {|r| r.Say("We're sorry, your call could not be verified.") }).text
  end

  nil
end

post "/" do
  if ( data = verify_call )
    return data
  end

  # Open the door since we're still automatically opening
  if $config["auto_open"]["ends_at"] and $config["auto_open"]["ends_at"] > Time.now.utc.to_i
    twiml = Twilio::TwiML::Response.new do |r|
      # DTMF tones can't be arbitrarily played back in Twilio.
      # http://www.dialabc.com/sound/generate/ will generate the DTMF sound easily
      r.Play($config["open_file"])
      r.Say("Welcome")
    end

    $config["auto_open"]["codes"].each do |code|
      notify_arrival($config["codes"][code])
    end
  # Require a passcode
  else
    code_length = $config["codes"].keys.first.to_s.length

    twiml = Twilio::TwiML::Response.new do |r|
      r.Gather(:numDigits => code_length, :timeout => $config["timeout"], :finishOnKey => "#", :action => "/code") do |g|
        g.Say("Please enter the #{code_length} digit code.")
      end
    end
  end

  return twiml.text
end

post "/code" do
  if ( data = verify_call )
    return data
  end

  if ( data = $config["codes"][params[:Digits].to_i] )
    notify_arrival(data)

    twiml = Twilio::TwiML::Response.new do |r|
      r.Play($config["open_file"])
      r.Say("Welcome")
    end
  else
    twiml = Twilio::TwiML::Response.new {|r| r.say("Sorry, that code is incorrect.")}
  end

  twiml.text
end

# Admin
def flush_config
  file = File.open("./config.yml", "w+")
  file.write(YAML.dump($config))
  file.close
end

def parse_number(number)
  number = number.gsub(/[^0-9]/, "")

  case number.length
    when 10 then "+1#{number}"
    when 11 then "+#{number}"
    else nil
  end
end

def format_phone(number)
  number.gsub(/\+1([0-9]{3})([0-9]{3})([0-9]{4})/, "(\\1) \\2-\\3")
end

def verify_admin
  #unless $validator.validate(request.url, params, request.env["HTTP_X_TWILIO_SIGNATURE"])
  #  return (Twilio::TwiML::Response.new {|r| r.SMS("Sorry, your request is invalid.")}).text
  #end

  nil
end

post "/sms" do
  if ( data = verify_admin )
    return data
  end

  twiml = nil
  cmd, args = params[:Body].split(" ", 2)
  cmd = cmd.downcase

  # Basic auth/deauth
  if cmd == "authorize"
    if $config["admin"]["password"] == data
      $config["admin"]["authorized"].push(params[:From])
      flush_config

      twiml = Twilio::TwiML::Response.new {|r| r.SMS("Authorized!")}
    else
      twiml = Twilio::TwiML::Response.new {|r| r.SMS("Access Denied.")}
    end

    return twiml.respond
  elsif cmd == "unauthorize"
    if $config["admin"]["password"] == data
      $config["admin"]["authorized"].delete(params[:From])
      flush_config

      twiml = Twilio::TwiML::Response.new {|r| r.SMS("Unauthorized this phone.")}
    else
      twiml = Twilio::TwiML::Response.new {|r| r.SMS("Access Denied.")}
    end

    return twiml.text
  end

  # Anything after we need to actually be authorized to this
  unless $config["admin"]["authorized"].include?(params[:From])
    return (Twilio::TwiML::Response.new {|r| r.SMS("Access Denied.")}).text
  end

  # Automatically unlock anytime someone asks it to for a set time limit
  if cmd == "unlock"
    amount, unit, codes = args.split(" ", 3)
    amount = amount.to_i

    $config["auto_open"]["ends_at"] = Time.now.utc
    $config["auto_open"]["codes"] = []
    if unit =~ /^seconds{0,}$/i
      $config["auto_open"]["ends_at"] += amount
    elsif unit =~ /^minutes{0,}$/i
      $config["auto_open"]["ends_at"] += amount * 60
    elsif unit =~ /^hours{0,}$/i
      $config["auto_open"]["ends_at"] += amount * 3600
    elsif unit =~ /^days{0,}$/i
      $config["auto_open"]["ends_at"] += amount * 86400
    end

    # Don't notify anyone on auto open
    if codes.nil?
      twiml = Twilio::TwiML::Response.new {|r| r.SMS("Door will auto unlock for the next #{amount} #{unit}.")}
    # Notify using the given codes
    else
      $config["auto_open"]["codes"] = codes.split(" ").map {|code| code.to_i}

      phones = ($config["auto_open"]["codes"].map {|data| format_phone(data["phone"])}).uniq
      twiml = Twilio::TwiML::Response.new {|r| r.SMS("Door will auto unlock for the next #{amount} #{unit}, and notify #{phones.join(", ")}.")}
    end

  # Stop auto unlocking early
  elsif cmd == "lock"
    $config["auto_open"]["ends_at"] = nil
    twiml = Twilio::TwiML::Response.new {|r| r.SMS("Door will no longer auto open.")}

  # Add a new code
  elsif cmd == "add-code"
    crt_length = $config["codes"].keys.first.to_s.length

    code, mode, phone, message = args.split(" ", 4)

    phone = params[:From] if phone == "me"
    code, phone = code.to_i, parse_phone(phone)

    if $config["codes"][code]
      twiml = Twilio::TwiML::Response.new {|r| r.SMS("The code #{code} is already in use.")}
    elsif code.to_s.length != crt_length
      twiml = Twilio::TwiML::Response.new {|r| r.SMS("All codes must be exactly #{crt_length} digits long.")}
    elsif mode != "text" and mode != "none"
      twiml = Twilio::TwiML::Response.new {|r| r.SMS("Invalid mode, must be either \"text\" or \"none\".")}
    elsif phone.nil? or phone == ""
      twiml = Twilio::TwiML::Response.new {|r| r.SMS("Invalid phone, must be either 10 or 11 digits.")}
    elsif mode != "none" and ( message.nil? or message == "" )
      twiml = Twilio::TwiML::Response.new {|r| r.SMS("No message given when the unlock code is used.")}
    # Added!
    else
      $config["codes"][code] = {"mode" => mode, "phone" => phone, "message" => message}
      twiml = Twilio::TwiML::Response.new {|r| r.SMS("Added new code #{code}, will #{mode == "none" && "not notify" || "#{mode} #{format_number(phone)}"} when someone arrives.")}
    end

  # Remove an added code
  elsif cmd == "rm-code"
    code = args.to_i

    $config["codes"].delete(code)
    twiml = Twilio::TwiML::Response.new {|r| r.SMS("Removed code #{code}.")}

  # Help!
  elsif cmd == "help"
    twiml = Twilio::TwiML::Response.new do |r|
        r.SMS("authorize <password>: Authorizes a new phone to use admin. unauthorize: Unauthorizes the phone.")
        r.SMS("unlock <amount> <minutes/hours/days>: How long to auto unlock the door. lock: Ends an auto unlock early.")
        r.SMS("add-code <code> <text/none> <phone> <message>: Adds a new passcode, as well as an optional notifier when the code is used. rm-code: Removes an added code.")
    end

    return twiml.text
  end

  flush_config
  twiml.text
end
