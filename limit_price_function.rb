# 苦戦し出したら止めた方が良いがする

require "json"
require "net/http"
require 'date'
require 'uri'
require 'time'
require 'jwt' # require: gem install 'jwt'
require 'pry' # require: gem install 'pry'
require 'slack-notifier' # require: gem install 'slack-notifier' and set slack channel token

# ex: ruby limit_price_function.rb btc 0.3 max_price

DEFAULT_CRYPTOCURRENCY_AMOUNT = 0.01 # 指定がなかった際のデフォルト取引量
ADJUST_CRYPTOCURRENCY_AMOUNT = 0.0005 # 仮想通貨取引量が理想値でなかった場合、この値ずつ加算していく（現状のデフォルトは小数点4桁の0.0005）
BUY_CHALENGEABLE_TIMES_LIMIT = 200 # 指値購入試行回数
SELL_CHALENGEABLE_TIMES_LIMIT = 250 # 指値売却試行回数
EARLY_SELL_SUCCESS_LINE = 150 # この数字以下の試行回数で売却に成功したら短期売買成功とみなす

CUT_OFF_STANDARD_PERCENTAGE = 50 # ex: 49 / 50 = 0.98のため、50の時は98.0%以下の価格が損切りラインとなる
CUT_OFF_STANDARD_AMOUNT = 12000 # ex: 12000の時は12000jpy以上下落したら損切りしてスクリプト自体を終了する
ERROR_COUNT_FOR_STOP_LINE = 500 # ex: 500の時は500回エラーを起こすと実行状況に問題ありと判断して強制終了する
BREAKING_JUDGE_TIMES = 4 # ex: 値を4に設定すると、5回連続で短期売買に成功したらインフレーション傾向ありとみなして少し様子見する
STOP_LINE = 5 # この値を越えたらスクリプト自体を終了する

PLICES_CONTINUE_TO_RISE_BREAK_SECONDS = 15 # インフレーション傾向時の様子見時間（秒）
PANIC_BREAK_SECONDS = 50 # 場荒れ時の様子見時間（秒）
UNEXPECTED_ERROR_BREAK_SECONDS = 100 # 予想外のエラー発生時の様子見時間（秒）

PUTS_HAVENOT_BUY_LOG_PERIOD = 10 # 購入チェックのログを、試行回数何回ごとに出力するかを決める
PUTS_HAVENOT_SELL_LOG_PERIOD = 15 # 売却チェックのログを、試行回数何回ごとに出力するかを決める

CRYPTOCURRENCY_TYPE = ARGV[0].to_s.upcase.gsub(' ', '')
UP_PRICE_ADJUST = ARGV[2].to_s == 'max_price'

# 取引所はLiquidを使用: https://www.liquid.com/ja
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

@error_count = 0
@buy_sell_script_stop = false
cut_off_times = 0
early_sell_success = 0
function_error_slack_call_flgs = Array.new(20).map(&:!) # 20個以上のフラグを使いたくなったら都度数を増やす
purchase_quantity = ARGV[1].to_f.nonzero? ? ARGV[1].to_f : DEFAULT_CRYPTOCURRENCY_AMOUNT

def private_liquid_api_call(parsed_url, http_method_type, params: {})
  sleep(1) # 連続で叩くとブロックされるため１秒空ける

  uri = URI.parse(parsed_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  auth_payload = {
    path: uri.path,
    nonce: DateTime.now.strftime('%Q'),
    token_id: TOKEN_ID
  }

  signature = JWT.encode(auth_payload, USER_SECRET, 'HS256')

  request = if http_method_type == 'get' || http_method_type == 'GET'
              Net::HTTP::Get.new(uri.path)
            elsif  http_method_type == 'post' || http_method_type == 'POST'
              Net::HTTP::Post.new(uri.path)
            elsif  http_method_type == 'put' || http_method_type == 'PUT'
              Net::HTTP::Put.new(uri.path)
            end

  request.body = params.to_json
  request.add_field('X-Quoine-API-Version', '2')
  request.add_field('X-Quoine-Auth', signature)
  request.add_field('Content-Type', 'application/json')

  http.request(request)
end

def public_liquid_api_call(parsed_url)
  sleep(1) # 連続で叩くとブロックされるため１秒空ける
  Net::HTTP.get_response(URI.parse(parsed_url))
end

def slack_call(title, text)
  notifier = Slack::Notifier.new(SLACK_APP_URL)
  attachments = [{
                   color: 'danger',
                   title: "#{title}",
                   text: "<!channel>\n#{text}",
                   mrkdwn_in: ['text'],
                   footer: 'generated my trade bot by Liquid',
                   ts: Time.now.to_i
                 }]
  notifier.ping('', attachments: attachments, username: 'daiki shibata')
end

def error_after_function(response, error_message, is_slack_call)
  puts_error(response, error_message)
  @error_count += 1

  slack_call(error_message, "check error message and account and script") if is_slack_call

  return if @error_count < ERROR_COUNT_FOR_STOP_LINE
  slack_call(error_message, "error total #{ERROR_COUNT_FOR_STOP_LINE}! Forced Stop!! check error message and account and script")
  @buy_sell_script_stop = true
  raise "error total #{ERROR_COUNT_FOR_STOP_LINE}!! check error message and account and script"
end

def puts_error(response, error_message)
  puts "============== #{error_message} =============="
  puts "status code#{response.code}!"
  puts "#{JSON.parse(response.body)}"
  puts "============== #{error_message} =============="
end

def puts_success(order, request_type_name)
  puts "============== #{request_type_name} =============="
  puts "order_id: #{order['id']} order_price: #{order['price']}"
  puts "============== #{request_type_name} =============="
end

def bit_coin_not_enough_free_balance?(response)
  begin
    response.code == '422' && JSON.parse(response.body)['errors']['user'][0] == 'not_enough_free_balance'
  rescue
    false
  end
end

def has_funds_check(response, coin_type)
  JSON.parse(response.body).select{ |res| res['currency'] == coin_type }[0]
end

class HTTPJsonResponseMock
  attr_accessor :code, :body

  def initialize(code: 200, body: '{ message: "no message"}')
    @code = code
    @body = body
  end
end

# 取引開始
while true do
  begin
    # 早期売却に数回成功している時は価格上昇が続いている状態のため、少し様子を見る
    if early_sell_success > BREAKING_JUDGE_TIMES
      puts '============== looks like prices continue to rise so I take a break ...  =============='
      sleep(PLICES_CONTINUE_TO_RISE_BREAK_SECONDS)
      early_sell_success = 0
    end

    # 1. 取引を始める前に手持ちの資金を確認して、損切りラインの基準となるデータを準備しておく
    puts '============== start check total =============='
    response = private_liquid_api_call('https://api.liquid.com/accounts/balance', 'GET')

    unless response.code == '200'
      error_after_function(response, 'has jpy check error 1', function_error_slack_call_flgs[0])
      function_error_slack_call_flgs[0] = false
      next
    end

    start_jpy_total = has_funds_check(response, 'JPY')
    puts "#{Time.now.strftime('%H:%M:%S')} #{start_jpy_total['currency']}: #{start_jpy_total['balance']}"
    first_total = start_jpy_total['balance'].to_i
    puts '============== start check total =============='
    # 1.

    # 2. 現在の仮想通貨の買値と売値の平均値を出し、指値の基準額を決定する
    response = public_liquid_api_call("https://api.liquid.com/executions?product_id=#{PRODUCT_ID}&limit=100&created_at=#{Time.now.to_i - 1}")

    unless response.code == '200'
      error_after_function(response, 'decide cryptocurrency limit price error 1', function_error_slack_call_flgs[1])
      function_error_slack_call_flgs[1] = false
      next
    end

    yakutei = JSON.parse(response.body)

    sells = yakutei['models'].map{ |y| y['price'].to_i if y['taker_side'] == 'sell' }.compact.sort
    buys = yakutei['models'].map{ |y| y['price'].to_i if y['taker_side'] == 'buy' }.compact.sort
    buys_limit_price = sells[(sells.length / 2)]
    sells_limit_price = buys[(buys.length / 2)]

    next unless sells_limit_price > buys_limit_price
    # 2.

    # 3. 指値で仮想通貨の購入注文を発行する
    return_to_the_beginning_1 = false
    while true do
      response = private_liquid_api_call(
        'https://api.liquid.com/orders',
        'POST',
        params: { order_type: 'limit', product_id: PRODUCT_ID, side: 'buy', quantity: purchase_quantity, price: buys_limit_price }
      )

      if response.code == '200'
        order = JSON.parse(response.body)
        puts_success(order, 'buy')
        current_has_coin_price = order['price'].to_i
        order_id = order['id']
        break
      elsif bit_coin_not_enough_free_balance?(response)
        purchase_quantity -= ADJUST_CRYPTOCURRENCY_AMOUNT
      else
        error_after_function(response, 'buy limit price cryptocurrency error', function_error_slack_call_flgs[2])
        function_error_slack_call_flgs[2] = false
        return_to_the_beginning_1 = true
        break
      end
    end
    next if return_to_the_beginning_1
    # 3.

    # 4. 購入注文が完遂するまでチェックを続けるが、一定時間が経っても購入ができなかったら注文をキャンセルする
    buy_check_count = 0
    return_to_the_beginning_2 = false
    continue_with_small_bit_coin = false
    while true do
      response = private_liquid_api_call('https://api.liquid.com/accounts/balance', 'GET')
      unless response.code == '200'
        error_after_function(response, "has #{CRYPTOCURRENCY_TYPE} check error 1", function_error_slack_call_flgs[3])
        function_error_slack_call_flgs[3] = false
        next
      end

      purchased_bit_coin = has_funds_check(response, CRYPTOCURRENCY_TYPE)['balance'].to_f

      break if purchased_bit_coin == purchase_quantity
      # 購入チェック...
      puts "haven't buy yet... challenge_count: #{buy_check_count}" if buy_check_count % PUTS_HAVENOT_BUY_LOG_PERIOD == 0
      buy_check_count += 1

      if buy_check_count > BUY_CHALENGEABLE_TIMES_LIMIT && purchase_quantity > purchased_bit_coin
        while true do
          response = private_liquid_api_call("https://api.liquid.com/orders/#{order_id}/cancel", 'PUT')

          # 仮想通貨が全く購入できていなかったら最初から仕切り直しにする
          if response.code == '200' && purchased_bit_coin == 0.0
            puts '============== cancel success! return to the beginning  =============='
            # 購入がなかなかできない時は場荒れし出していると判断して少し様子見する
            puts '============== looks like panic so I take a break ...  =============='
            early_sell_success = 0
            return_to_the_beginning_2 = true
            sleep(PANIC_BREAK_SECONDS)
            break
          # 仮想通貨を少額購入していたらキャンセル後に所有している仮想通貨の量を再度計算してその仮想通貨だけを売りにかける
          elsif response.code == '200' && purchased_bit_coin > 0.0
            puts '============== cancel success! continue with small bit coin =============='
            continue_with_small_bit_coin = true

            while true do
              response = private_liquid_api_call('https://api.liquid.com/accounts/balance', 'GET')
              if response.code == '200'
                purchase_quantity = has_funds_check(response, CRYPTOCURRENCY_TYPE)['balance'].to_f
                break
              else
                error_after_function(response, "has #{CRYPTOCURRENCY_TYPE} check error 2", function_error_slack_call_flgs[4])
                function_error_slack_call_flgs[4] = false
              end
            end
            break
          else
            error_after_function(response, 'cancel failer 1', function_error_slack_call_flgs[5])
            function_error_slack_call_flgs[5] = false
          end
        end
      end
      break if return_to_the_beginning_2 || continue_with_small_bit_coin
    end
    next if return_to_the_beginning_2
    # 4.

    # 5. 指値で仮想通貨の売却注文を発行する
    while true do
      response = private_liquid_api_call(
        'https://api.liquid.com/orders',
        'POST',
        params: { order_type: 'limit', product_id: PRODUCT_ID, side: 'sell', quantity: purchase_quantity, price: sells_limit_price }
      )

      if response.code == '200'
        order = JSON.parse(response.body)
        puts_success(order, 'sell')
        break
      else
        error_after_function(response, 'sell limit price cryptocurrency error', function_error_slack_call_flgs[6])
        function_error_slack_call_flgs[6] = false
      end
    end
    # 5.

    # 6. 売却注文が完遂するまでチェックを続けるが、一定時間経っても売却ができなかったり価格が下がりすぎたら損切り注文を行い最初から仕切り直しにする
    sell_check_count = 0
    stop_check = false
    while true do
      response = private_liquid_api_call('https://api.liquid.com/accounts/balance', 'GET')

      unless response.code == '200'
        error_after_function(response, "has jpy and #{CRYPTOCURRENCY_TYPE} check error", function_error_slack_call_flgs[7])
        function_error_slack_call_flgs[7] = false
        next
      end

      all_has = JSON.parse(response.body)
      has_bit_coin_total = all_has.select{ |res| res['currency'] == CRYPTOCURRENCY_TYPE }[0]['balance'].to_f
      jpy_total = all_has.select{ |res| res['currency'] == 'JPY' }[0]['balance'].to_f

      if has_bit_coin_total == 0.0
        early_sell_success = sell_check_count < EARLY_SELL_SUCCESS_LINE ? early_sell_success + 1 : 0
        break
      end

      # 売却チェック...
      puts "haven't sell yet... challenge_count: #{sell_check_count}" if sell_check_count % PUTS_HAVENOT_SELL_LOG_PERIOD == 0
      sell_check_count += 1

      response = public_liquid_api_call("https://api.liquid.com/executions?product_id=#{PRODUCT_ID}&limit=100&created_at=#{Time.now.to_i - 1}")

      unless response.code == '200'
        error_after_function(response, 'decide cryptocurrency limit price error 2', function_error_slack_call_flgs[8])
        function_error_slack_call_flgs[8] = false
        next
      end

      yakutei = JSON.parse(response.body)
      check_buys = yakutei['models'].map{ |y| y['price'].to_i if y['taker_side'] == 'buy' }.compact.sort
      check_ava_buys = check_buys[(check_buys.length / 2)].to_i

      response = public_liquid_api_call("https://api.liquid.com/products/#{PRODUCT_ID}")
      current_total = if response.code == '200'
                        bit_coin_price = JSON.parse(response.body)['market_ask'].to_f
                        has_bit_coin_total * bit_coin_price + jpy_total
                      else
                        error_after_function(response, 'bit coin price check error', function_error_slack_call_flgs[9])
                        function_error_slack_call_flgs[9] = false
                        nil
                      end

      purchased_coins_fell_1_5_percent = check_ava_buys < current_has_coin_price - (current_has_coin_price / CUT_OFF_STANDARD_PERCENTAGE).to_i
      funds_decreased_by_1_5_percent_jpy = current_total && first_total - CUT_OFF_STANDARD_AMOUNT >= current_total
      # ex: 損切り条件 => 購入した仮想通貨の価格が1.5%以上下落 or 12000のjpyの損が確定 or 10000回試行しても売却できない（機会損失）
      # 12000以上のjpyの損が確定した場合は暴落が発生していると判断して売買自体を停止する
      if purchased_coins_fell_1_5_percent || funds_decreased_by_1_5_percent_jpy || sell_check_count > SELL_CHALENGEABLE_TIMES_LIMIT
        funds_decreased_by_1_5_percent_jpy ? stop_check = true : cut_off_times += 1

        # 全ての注文をキャンセル
        while true do
          response = private_liquid_api_call('https://api.liquid.com/orders?status=live', 'GET')

          unless response.code == '200'
            error_after_function(response, 'has my order check error 1', function_error_slack_call_flgs[10])
            function_error_slack_call_flgs[10] = false
            next
          end

          response = JSON.parse(response.body)
          break if !response['models'] || (response['models'].is_a?(Array) && response['models'].filter{ |r| r['status'] == 'live' }.length == 0)

          response['models'].filter{ |r| r['status'] == 'live' }.map{ |r| r['id'] }.each do |o_id|
            response = private_liquid_api_call("https://api.liquid.com/orders/#{o_id}/cancel", 'PUT')
            unless response.code == '200'
              error_after_function(response, 'cancel failer 2', function_error_slack_call_flgs[11])
              function_error_slack_call_flgs[11] = false
              next
            end
          end

          response = private_liquid_api_call('https://api.liquid.com/orders?status=live', 'GET')

          unless response.code == '200'
            error_after_function(response, 'has my order check error 2', function_error_slack_call_flgs[12])
            function_error_slack_call_flgs[12] = false
            next
          end

          response = JSON.parse(response.body)
          break if !response['models'] || (response['models'].is_a?(Array) && response['models'].filter{ |r| r['status'] == 'live' }.length == 0)
          order_ids = response['models'].filter{ |r| r['status'] == 'live' }.map{ |r| r['id'] }
          break order_ids.empty?
        end

        # 所有している仮想通貨を全て損切り（成行）で売却する
        while true do
          response = private_liquid_api_call('https://api.liquid.com/accounts/balance', 'GET')
          unless response.code == '200'
            error_after_function(response, "has #{CRYPTOCURRENCY_TYPE} check error 1", function_error_slack_call_flgs[13])
            function_error_slack_call_flgs[13] = false
            next
          end

          purchased_bit_coin = has_funds_check(response, CRYPTOCURRENCY_TYPE)['balance'].to_f

          response = private_liquid_api_call(
            'https://api.liquid.com/orders',
            'POST',
            params: { order_type: 'market', product_id: PRODUCT_ID, side: 'sell', quantity: purchased_bit_coin }
          )

          if response.code == '200'
            puts_success(order, 'loss cut success')
            puts 'Lost Cut! Look carefully at the chart!!'
            slack_call("#{current_total} Lost Cut!", 'Lost Cut! Look carefully at the chart!!')
            early_sell_success = 0
            break
          else
            error_after_function(response, 'loss cut failer', function_error_slack_call_flgs[14])
            function_error_slack_call_flgs[14] = false
          end
        end

        break
      end
    end
    # 6.

    # 7. 結果を確認して続行するか終了するかを決定する
    if stop_check || STOP_LINE < cut_off_times
      puts 'Lost lot! Today end!'
      slack_call("#{CUT_OFF_STANDARD_AMOUNT} Lost!", 'Lost lot! Today end!! check error message and account and script!')
      break
    else
      purchase_quantity += ADJUST_CRYPTOCURRENCY_AMOUNT if UP_PRICE_ADJUST
      puts 'good job...'
    end
    # 7.
  rescue => e
    if @buy_sell_script_stop
      break
    else
      error_after_function(HTTPJsonResponseMock.new(code: 500, body: "{ message: '#{e.message}'}"), "unexpected error!(#{e.message})", true)
      sleep(UNEXPECTED_ERROR_BREAK_SECONDS)
    end
  end
end
