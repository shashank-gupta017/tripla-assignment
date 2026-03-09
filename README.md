<div align="center">
   <img src="/img/logo.svg?raw=true" width=600 style="background-color:white;">
</div>

# Backend Engineering Take-Home Assignment: Dynamic Pricing Proxy

Welcome to the Tripla backend engineering take-home assignment\! 🧑‍💻 This exercise is designed to simulate a real-world problem you might encounter as part of our team.


## The Challenge

At Tripla, we use a dynamic pricing model for hotel rooms. Instead of static, unchanging rates, our model uses a real-time algorithm to adjust prices based on market demand and other data signals. This helps us maximize both revenue and occupancy.

Our Data and AI team built a powerful model to handle this, but its inference process is computationally expensive to run. To make this product more cost-effective, we analyzed the model's output and found that a calculated room rate remains effective for up to 5 minutes.

This insight presents a great optimization opportunity, and that's where you come in.

## Your Mission

Your mission is to build an efficient service that acts as an intermediary to our dynamic pricing model. This service will be responsible for providing rates to our users while respecting the operational constraints of the expensive model behind it.

You will start with a Ruby on Rails application that is already integrated with our dynamic pricing model. However, the current implementation fetches a new rate for every single request. Your mission is to ensure this service handles the pricing models' constraints.

## Core Requirements

1. Review the pricing model's API and its constraints. The model's docker image and documentation are hosted on dockerhub:  [tripladev/rate-api](https://hub.docker.com/r/tripladev/rate-api).

2. Ensure rate validity. A rate fetched from the pricing model is considered valid for 5 minutes. Your service must ensure that any rate it provides for a given set of parameters (`period`, `hotel`, `room`) is no older than this 5-minute window.

3. Honor throughput requirements. Your solution must be able to handle at least 10,000 requests per day from our users while using a single API token.

## How We'll Evaluate Your Work

This isn't just about getting the right answer. We're excited to see how you approach the problem. Treat this as you would a production-ready feature.

  * We'll be looking for clean, well-structured, and testable code. Feel free to add dependencies or refactor the existing scaffold as you see fit.
  * How do you decide on your approach to meeting the performance and cost requirements? Documenting your thought process is a great way to share this.
  * A reliable service anticipates failure. How does your service behave if the pricing model is slow, or returns an error? Providing descriptive error messages to the end-user is a key part of a robust API.
  * We want to see how you work around constraints and navigate an existing codebase to deliver a solution.


## Minimum Deliverables

1.  A link to your Git repository containing the complete solution.
2.  Clear instructions in the `README.md` on how to build, test, and run your service.

We highly value seeing your thought process. A great submission will also include documentation (e.g., in the `README.md`) discussing the design choices you made. Consider outlining different approaches you considered, their potential tradeoffs, and a clear rationale for why you chose your final solution.

## Development Environment Setup

The project scaffold is a minimal Ruby on Rails application with a `/api/v1/pricing` endpoint. While you're free to configure your environment as you wish, this repository is pre-configured for a Docker-based workflow that supports live reloading for your convenience.

The provided `Dockerfile` builds a container with all necessary dependencies. Your local code is mounted directly into the container, so any changes you make on your machine will be reflected immediately. Your application will need to communicate with the external pricing model, which also runs in its own Docker container.

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (includes Docker Compose)
- No local Ruby installation required — everything runs inside the container

### Quick Start Guide

List of common commands for building, running, and interacting with the Dockerized environment.

```bash
# --- 1. Build & Start ---
docker compose up -d --build

# --- 2. Verify the service is running ---
curl 'http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'
# Expected response:
# {"rate":"15000"} --> The rate value can differ after the container is re-built and re-run.

# --- 3. Verify caching works ---
# Run the same request twice — the second call is served from cache.
# Check the Rails logs to confirm the rate-api container receives only one request:
docker compose logs interview-dev
# Look for: [PricingService] Cache HIT for pricing/Summer/FloatingPointResort/SingletonRoom

# --- 4. Run the full test suite ---
docker compose exec interview-dev ./bin/rails test
# Expected output: 15 runs, 37 assertions, 0 failures, 0 errors, 0 skips

# --- 5. Run a specific test file ---
docker compose exec interview-dev ./bin/rails test test/controllers/pricing_controller_test.rb

# --- 6. Run a specific test by name ---
docker compose exec interview-dev ./bin/rails test test/controllers/pricing_controller_test.rb -n test_should_get_pricing_with_all_parameters

# --- 7. Stop the containers ---
docker compose down
```


---

## Solution

### Design: Batch-All-On-Miss Caching

The core constraint is:

```
≥ 10,000 user requests/day
  1,000 upstream API calls/day (hard limit)
  rates valid for 5 minutes
```

There are only **36 unique combinations** of the three input parameters:

| Dimension | Values | Count |
|---|---|---|
| `period` | Summer, Autumn, Winter, Spring | 4 |
| `hotel` | FloatingPointResort, GitawayHotel, RecursionRetreat | 3 |
| `room` | SingletonRoom, BooleanTwin, RestfulKing | 3 |

**4 × 3 × 3 = 36**

#### Why naive per-key caching doesn't work

Caching each key individually on first request sounds simple, but hits the limit:

```
36 unique keys × 288 five-minute windows/day = 10,368 API calls/day  ❌ OVER LIMIT
```

#### The batch-all-on-miss strategy

The rate-api supports **batch requests** — all 36 combinations in a single call. On any cache miss, we fetch all 36 at once and write them all to the cache:

```
1 batch call per five-minute window × 288 windows/day = 288 calls/day  ✅ 3.5× headroom
```

This means the upstream API is called **at most once every 5 minutes**, regardless of user traffic volume. Cache hits are served in memory in under 1ms.

#### Cache key format

```
pricing/{period}/{hotel}/{room}
# e.g. pricing/Summer/FloatingPointResort/SingletonRoom
```

Namespaced under `pricing/` to avoid collisions. All 36 keys are pre-populated on every batch warm.

### Error Handling

Every failure mode returns a meaningful HTTP status and message:

| Scenario | HTTP Status | Trigger |
|---|---|---|
| Invalid input params | 400 Bad Request | Controller validation before service is called |
| Upstream timeout | 503 Service Unavailable | `Net::OpenTimeout` / `Net::ReadTimeout` |
| Rate-api rate-limited | 429 Too Many Requests | Upstream returns HTTP 429 |
| Upstream server error | 502 Bad Gateway | Upstream returns non-2xx, non-429 |
| Rate not in response | 404 Not Found | Batch response contains no matching key |
| Unexpected exception | 500 Internal Server Error | Unhandled `StandardError` (logged) |

A 5-second `default_timeout` is set on `RateApiClient` to prevent thread exhaustion if the upstream is slow.

### Assumptions

1. The rate-api batch response always returns a `rates` array with `period`, `hotel`, `room`, and `rate` keys — consistent with the Docker Hub documentation.
2. Input validation (enum whitelisting) is sufficient — no further sanitization is needed at the cache layer since only valid values reach the service.

### Cache Store Choice: Memory vs Redis

| Option | Chosen? | Reason |
|---|---|---|
| `Rails.cache` `:memory_store` | ✅ Yes | Zero extra infrastructure; 36 keys × ~50 bytes = ~1.8 KB footprint; single-process Docker deployment |
| Redis | ❌ Not for this assignment | Required for multi-worker/multi-instance environments; swappable with one config line change when needed |

Switching to Redis in future requires only a one-line change in `config/environments/production.rb` — no application logic changes.

### Why not `Rails.cache.fetch`?

`Rails.cache.fetch(key) { ... }` is the idiomatic read-through pattern, but it only fetches and writes **one key at a time**. Since we want to write **all 36 keys** from a single batch API response, we need explicit `read` / `write` calls. Using `fetch` here would require 36 separate API calls on a cold cache, defeating the batching strategy entirely.

### Future Improvements

- **Redis cache store** — required if the app needs to scale beyond a single instance at production scale.
- **Background cache warming** — a Background job could proactively refresh the cache before expiry, eliminating the first-request latency on a cold cache after a TTL window
- **Circuit breaker Pattern** — wrap the `RateApiClient` calls with a circuit breaker implementation to fail fast when the upstream is consistently unavailable, rather than exhausting threads on timeouts
- **Retry with exponential backoff** — transient failures (network hiccupts, brief upstream overload) could be retried automatically in `RateApiClient` before surfacing a 503 to the caller. Exponential backoff (e.g. retry after 1s, 2s, 4s) with a jitter component avoids thundering-herd scenarios where all retries hit the upstream simultaneously. This is particularly valuable for the batch warm call — a single failed warm leaves all 36 keys stale, so one successful retry has high leverage

### AI Tool Usage

This solution was developed with GitHub Copilot CLI as an AI assistant. Copilot was used throughout:

- **Planning**: generating the implementation plan, identifying the batch-all-on-miss strategy, and mapping the math (36 × 288 = 10,368 > 1,000)
- **Implementation**: writing `PricingService`, `RateApiClient`, `PricingConstants`, and the cache configuration
- **Testing**: writing the full test suite including edge cases (malformed JSON, missing `rates` key, `Net::OpenTimeout`)
- **Debugging**: diagnosing the Windows CRLF line-ending issue in the Docker container and the clearing of cache state between each test execution to avoid cache state leakage between tests
- **README**: update the README file.

All generated code was reviewed, understood, and verified by running the full test suite and manual curl tests. Every design decision documented above reflects a genuine understanding of the trade-offs involved.

