require 'json'
require 'net/http'
require 'date'
require 'uri'
require 'time'
require 'jwt'
require 'pry'
require 'slack-notifier'

# ex: ruby limit_price_function.rb btc 0.03 buy

CRYPTOCURRENCY_TYPE = ARGV[0].to_s.upcase.gsub(' ', '')
QUANTITY = ARGV[1].to_f.nonzero? ? ARGV[1].to_f : 0.03
TOKEN_ID = ENV['LIQUID_TOKEN_ID']
USER_SECRET = ENV['LIQUID_USER_SECRET']
SLACK_APP_URL = ENV['LIQUID_SLACK_APP']

# 随時追記する
PRODUCT_ID = case CRYPTOCURRENCY_TYPE
             when 'BTC'
               5
             else
               5
             end
COMMAND_TYPE = ARGV[2].to_s.upcase.gsub(' ', '')

if COMMAND_TYPE == 'BUY'
  uri = URI.parse('https://api.liquid.com/orders')
  params = { order_type: 'market', product_id: PRODUCT_ID, side: 'buy', quantity: QUANTITY }
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  auth_payload = {
    path: uri.path,
    nonce: DateTime.now.strftime('%Q'),
    token_id: TOKEN_ID
  }

  signature = JWT.encode(auth_payload, USER_SECRET, 'HS256')

  request = Net::HTTP::Post.new(uri.path)
  request.add_field('X-Quoine-API-Version', '2')
  request.add_field('X-Quoine-Auth', signature)
  request.add_field('Content-Type', 'application/json')
  request.body = params.to_json

  response = http.request(request)

  if response.code == '200'
    order = JSON.parse(response.body)
    puts '============== buy =============='
    puts order['id']
    puts order['price']
    puts '============== buy =============='

    current_has_coin_price = (order['price'].to_f * 100).to_i
    cut_off_price = current_has_coin_price - (current_has_coin_price / 20)
  else
    puts '============== buy error =============='
    puts "status code#{response.code}!"
    puts "#{JSON.parse(response.body)}"
    puts '============== buy error =============='
    return 'error'
  end
end

if COMMAND_TYPE == 'SELL'
  uri = URI.parse('https://api.liquid.com/orders')
  params = { order_type: 'market', product_id: PRODUCT_ID, side: 'sell', quantity: QUANTITY }
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  auth_payload = {
    path: uri.path,
    nonce: DateTime.now.strftime('%Q'),
    token_id: TOKEN_ID
  }

  signature = JWT.encode(auth_payload, USER_SECRET, 'HS256')

  request = Net::HTTP::Post.new(uri.path)
  request.add_field('X-Quoine-API-Version', '2')
  request.add_field('X-Quoine-Auth', signature)
  request.add_field('Content-Type', 'application/json')
  request.body = params.to_json

  response = http.request(request)

  if response.code == '200'
    order = JSON.parse(response.body)
    puts '============== sell =============='
    puts order['id']
    puts order['price']
    puts '============== sell =============='
  else
    puts '============== sell error =============='
    puts "status code#{response.code}!"
    puts "#{JSON.parse(response.body)}"
    puts '============== sell error =============='
    return 'error'
  end
end

if COMMAND_TYPE == 'CHECK'
  uri = URI.parse("https://api.liquid.com/products/#{PRODUCT_ID}")
  response = Net::HTTP.get_response(uri)

  if response.code == '200'
    puts bit_coin_price = JSON.parse(response.body)['market_ask']
  else
    puts '============== error =============='
  end
end

if COMMAND_TYPE == 'SLACK'
  notifier = Slack::Notifier.new(SLACK_APP_URL)
  attachments = [{
                   color: 'danger',
                   title: 'test',
                   text: "<!channel>\ntestsample",
                   mrkdwn_in: ['text'],
                   footer: 'generated by Liquid my trade bot',
                   ts: Time.now.to_i
                 }]
  notifier.ping('', attachments: attachments, username: 'daiki shibata')
end
