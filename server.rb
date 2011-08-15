require "twiliolib"

@config = YAML::load(File.read("./config.yml"))

@util = Twilio::Utils.new(@config["twilio"]["sid"], @config["twilio"]["token"])

# General door handling
def notify_arrival(data)
  return if data["mode"] == "none"
end

def verify_call
  unless @util.validateRequest(request.env["HTTP_X_TWILIO_SIGNATURE"], request.url, params)
    twiml = Twilio::Response.new
    twiml.append(Twilio::Say.new("We're sorry, your call could not be verified."))
    return twiml.respond
  end

  unless params["From"] == @config["require_from"]
    twiml = Twilio::Response.new
    twiml.append(Twilio::Say.new("We're sorry, your call could not be verified."))
    return twiml.respond
  end

  nil
end

post "/" do
  if ( data = verify_call )
    return data
  end

  twiml = Twilio::Response.new

  # Open the door since we're still automatically opening
  if @config["auto_open"]["ends_at"] and @config["auto_open"]["ends_at"] > Time.now.utc.to_i
    # Enter digits
    twiml.append(Twilio::Say.new("Welcome"))

    @config["auto_open"]["codes"].each do |code|
      notify_arrival(@config["codes"][code])
    end
  # Require a passcode
  else
    code_length = @config["codes"].keys.first.to_s.length

    gather = Twilio::Gather.new(:numDigits => code_length, :timeout => @config["admin"]["timeout"], :finishOnKey => "#", :action => "/code")
    gather.append(Twilio::Say.new("Please enter the #{code_length} digit code."))
    twiml.append(gather)
  end

  return twiml.respond
end

post "/code" do
  if ( data = verify_call )
    return data
  end

  twiml = Twilio::Response.new

  if ( data = @config["codes"][params["Digits"].to_i] )
    # Enter digits
    twiml.append(Twilio::Say.new("Welcome"))

    notify_arrival(data)
  else
    twiml.append(Twilio::Say.new("Sorry, that code is incorrect."))
  end

  twiml.respond
end

# Admin
def flush_config
  file = File.open("./config.yml", "w+")
  file.write(YAML::generate(@config))
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
  unless @util.validateRequest(request.env["HTTP_X_TWILIO_SIGNATURE"], request.url, params)
    twiml = Twilio::Response.new
    twiml.append(Twilio::Say.new("Sorry, your request is invalid."))
    return twiml.respond
  end

  nil
end

post "/sms" do
  if ( data = verify_admin )
    return data
  end

  twiml = Twilio::Response.new
  cmd, args = params["Message"].split(" ", 2)

  # Basic auth/deauth
  if cmd == "authorize"
    if @config["admin"]["password"] == data
      @config["admin"]["authorized"].push(params["Called"])
      flush_config

      twiml.append(Twilio::Say.new("Number authorized."))
    else
      twiml.append(Twilio::Say.new("Access denied."))
    end

    return twiml.respond
  elsif cmd == "deauthorize"
    if @config["admin"]["password"] == data
      @config["admin"]["authorized"].delete(params["Called"])
      flush_config

      twiml.append(Twilio::Say.new("Number de-authorized."))
    else
      twiml.append(Twilio::Say.new("Access denied."))
    end

    return twiml.respond
  end

  # Anything after we need to actually be authorized to this
  unless @config["admin"]["authorized"].include?(params["Called"])
    twiml.append(Twilio::Say.new("Access denied."))
    return twiml.respond
  end

  # Automatically unlock anytime someone asks it to for a set time limit
  if cmd == "unlock"
    amount, unit, codes = args.split(" ", 3)
    amount = amount.to_i

    @config["auto_open"]["ends_at"] = Time.now.utc
    @config["auto_open"]["codes"] = []
    if unit =~ /^seconds{0,}$/i
      @config["auto_open"]["ends_at"] += amount
    elsif unit =~ /^minutes{0,}$/i
      @config["auto_open"]["ends_at"] += amount * 60
    elsif unit =~ /^hours{0,}$/i
      @config["auto_open"]["ends_at"] += amount * 3600
    elsif unit =~ /^days{0,}$/i
      @config["auto_open"]["ends_at"] += amount * 86400
    end

    # Don't notify anyone on auto open
    if codes.nil?
      twiml.append(Twilio::Say.new("Door will auto unlock for the next #{amount} #{unit}."))
    # Notify using the given codes
    else
      @config["auto_open"]["codes"] = codes.split(" ").map {|code| code.to_i}

      phones = (@config["auto_open"]["codes"].map {|data| data["phone"]}).uniq
      twiml.append(Twilio::Say.new("Door will auto unlock for #{amount} #{unit} and notify #{phones.join(", ")}."))
    end

  # Stop auto unlocking early
  elsif cmd == "lock"
    @config["auto_open"]["ends_at"] = nil
    twiml.append(Twilio::Say.new("Door will no longer auto open."))

  # Add a new code
  elsif cmd == "add-code"
    crt_length = @config["codes"].keys.first.to_s.length

    code, mode, phone, message = args.split(" ", 4)

    phone = params["Called"] if phone == "me"
    code, phone = code.to_i, parse_phone(phone)

    if @config["codes"][code]
      twiml.append(Twilio::Say.new("The code #{code} is already in use."))
    elsif code.to_s.length != crt_length
      twiml.append(Twilio::Say.new("All codes must be exactly #{crt_length} digits long."))
    elsif mode != "text" and mode != "call" and mode != "none"
      twiml.append(Twilio::Say.new("Invalid mode, must be either \"text\", \"call\" or \"none\"."))
    elsif phone.nil? or phone == ""
      twiml.append(Twilio::Say.new("Invalid phone entered, must either be a valid number or \"me\"."))
    elsif mode != "none" and ( message.nil? or message == "" )
      twiml.append(Twilio::Say.new("No message given notify when the unlock is used."))
    # Added!
    else
      @config["codes"][code] = {"mode" => mode, "phone" => phone, "message" => message}
      twiml.append(Twilio::Say.new("Added new code #{code}, will #{mode == "none" && "not notify" || "#{mode} #{format_number(phone)}"} when someone arrives."))
    end

  # Remove an added code
  elsif cmd == "rm-code"
    code = args.to_i

    @config["codes"].delete(code)
    twiml.append(Twilio::Say.new("Removed code #{code}."))
  end

  flush_config
  twiml.respond
end