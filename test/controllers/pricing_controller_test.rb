require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  # --- Helpers ---

  def mock_batch_response(rates = default_rates)
    OpenStruct.new(success?: true, body: { 'rates' => rates }.to_json)
  end

  def default_rates
    [{ 'period' => 'Summer', 'hotel' => 'FloatingPointResort', 'room' => 'SingletonRoom', 'rate' => '15000' }]
  end

  def pricing_params
    { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
  end

  # --- Happy path ---

  test "should get pricing with all parameters" do
    RateApiClient.stub(:get_rates, mock_batch_response) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :success
      assert_equal "application/json", @response.media_type
      assert_equal "15000", JSON.parse(@response.body)["rate"]
    end
  end

  # --- Cache behaviour ---

  test "should return cached rate without calling API again" do
    api_call_count = 0
    counting_stub  = ->(**) { api_call_count += 1; mock_batch_response }

    RateApiClient.stub(:get_rates, counting_stub) do
      # First request — cache miss, API must be called
      get api_v1_pricing_url, params: pricing_params
      assert_response :success

      # Second request — cache hit, API must NOT be called again
      get api_v1_pricing_url, params: pricing_params
      assert_response :success
    end

    assert_equal 1, api_call_count, "API should only be called once — second request must be served from cache"
  end

  test "should warm all combinations on a cache miss" do
    received_attributes = nil
    capturing_stub = ->(attributes:) { received_attributes = attributes; mock_batch_response }

    RateApiClient.stub(:get_rates, capturing_stub) do
      get api_v1_pricing_url, params: pricing_params
    end

    assert_equal 36, received_attributes.size, "Batch request must include all 36 period/hotel/room combinations"
  end

  # --- Error handling ---

  test "should return 503 when rate API times out" do
    RateApiClient.stub(:get_rates, ->(**) { raise Net::ReadTimeout }) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :service_unavailable
      assert_includes JSON.parse(@response.body)["error"], "timed out"
    end
  end

  test "should return 503 when rate API connection times out" do
    RateApiClient.stub(:get_rates, ->(**) { raise Net::OpenTimeout }) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :service_unavailable
      assert_includes JSON.parse(@response.body)["error"], "timed out"
    end
  end

  test "should return 429 when rate API is rate limited" do
    mock_response = OpenStruct.new(success?: false, code: 429, body: {}.to_json)

    RateApiClient.stub(:get_rates, mock_response) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :too_many_requests
      assert_includes JSON.parse(@response.body)["error"], "Rate limit exceeded"
    end
  end

  test "should return 502 when rate API returns a server error" do
    mock_response = OpenStruct.new(success?: false, code: 500, body: { 'error' => 'internal error' }.to_json)

    RateApiClient.stub(:get_rates, mock_response) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :bad_gateway
      assert_includes JSON.parse(@response.body)["error"], "Pricing service error"
    end
  end

  test "should return 404 when rate not found in API response" do
    RateApiClient.stub(:get_rates, mock_batch_response([])) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :not_found
    end
  end

  # --- Defensive / edge cases ---

  test "should return 500 when rate API returns malformed JSON" do
    mock_response = OpenStruct.new(success?: true, body: "not-valid-json{{")

    RateApiClient.stub(:get_rates, mock_response) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :internal_server_error
    end
  end

  test "should return 404 when API response is missing rates key" do
    mock_response = OpenStruct.new(success?: true, body: { 'data' => [] }.to_json)

    RateApiClient.stub(:get_rates, mock_response) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :not_found
    end
  end

  # --- Input validation ---

  test "should return error without any parameters" do
    get api_v1_pricing_url

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Missing required parameters"
  end

  test "should handle empty parameters" do
    get api_v1_pricing_url, params: { period: "", hotel: "", room: "" }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Missing required parameters"
  end

  test "should reject invalid period" do
    get api_v1_pricing_url, params: { period: "summer-2024", hotel: "FloatingPointResort", room: "SingletonRoom" }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid period"
  end

  test "should reject invalid hotel" do
    get api_v1_pricing_url, params: { period: "Summer", hotel: "InvalidHotel", room: "SingletonRoom" }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid hotel"
  end

  test "should reject invalid room" do
    get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "InvalidRoom" }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid room"
  end
end
