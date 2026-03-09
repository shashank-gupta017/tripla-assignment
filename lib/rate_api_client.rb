class RateApiClient
  include HTTParty
  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  headers 'Content-Type' => 'application/json'
  headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')
  default_timeout 5  # prevent Puma thread starvation on a slow upstream

  # Fetches rates for multiple attribute combinations in a single API call.
  # attributes: Array of hashes, e.g. [{ period:, hotel:, room: }, ...]
  def self.get_rates(attributes:)
    post('/pricing', body: { attributes: attributes }.to_json)
  end
end
