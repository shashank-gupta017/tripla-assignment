module Api::V1
  class PricingService < BaseService
    include PricingConstants

    CACHE_TTL       = 5.minutes
    CACHE_NAMESPACE = 'pricing'

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel  = hotel
      @room   = room
    end

    def run
      cache_key = build_cache_key(@period, @hotel, @room)

      cached_rate = Rails.cache.read(cache_key)
      if cached_rate
        Rails.logger.info "[PricingService] Cache HIT for #{cache_key}"
        @result = cached_rate
        return
      end

      Rails.logger.info "[PricingService] Cache MISS for #{cache_key} — warming all 36 keys"
      warm_cache!

      # If warm_cache! encountered an error, stop here — don't overwrite the error status
      return if errors.any?

      @result = Rails.cache.read(cache_key)
      unless @result
        @error_status = :not_found
        errors << "Rate not found for the given parameters."
      end
    end

    private

    # Calls rate-api once with ALL 36 valid combinations.
    # Writes every returned rate into the cache with a 5-minute TTL.
    # This caps upstream usage at ~288 calls/day regardless of traffic volume.
    def warm_cache!
      attributes = VALID_PERIODS.product(VALID_HOTELS, VALID_ROOMS).map do |period, hotel, room|
        { period: period, hotel: hotel, room: room }
      end

      response = RateApiClient.get_rates(attributes: attributes)

      if response.success?
        parsed = JSON.parse(response.body)
        rates = parsed['rates'] || []
        rates.each do |rate_entry|
          key = build_cache_key(rate_entry['period'], rate_entry['hotel'], rate_entry['room'])
          Rails.cache.write(key, rate_entry['rate'], expires_in: CACHE_TTL)
        end
        Rails.logger.info "[PricingService] Cache warmed: #{rates.size} keys written (TTL: #{CACHE_TTL})"
      elsif response.code == 429
        Rails.logger.warn "[PricingService] Rate API rate-limited (429)"
        @error_status = :too_many_requests
        errors << "Rate limit exceeded. The pricing service is temporarily unavailable."
      else
        Rails.logger.error "[PricingService] Rate API error: HTTP #{response.code}"
        @error_status = :bad_gateway
        body = JSON.parse(response.body) rescue {}
        errors << "Pricing service error: #{body['error'] || response.code}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      Rails.logger.warn "[PricingService] Rate API timeout (#{e.class})"
      @error_status = :service_unavailable
      errors << "Pricing service timed out. Please try again."
    rescue StandardError => e
      Rails.logger.error "[PricingService] Unexpected error: #{e.class}: #{e.message}"
      @error_status = :internal_server_error
      errors << "An unexpected error occurred."
    end

    def build_cache_key(period, hotel, room)
      "#{CACHE_NAMESPACE}/#{period}/#{hotel}/#{room}"
    end
  end
end
