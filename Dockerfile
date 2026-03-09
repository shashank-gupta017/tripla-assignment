# syntax = docker/dockerfile:1

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version and Gemfile
ARG RUBY_VERSION=3.2.6
FROM ruby:$RUBY_VERSION-alpine

# Rails app lives here
WORKDIR /rails

# Set development environment
ENV RAILS_ENV="development" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT=""

# Optional: inject a corporate CA certificate at build time to allow apk and
# bundler to reach HTTPS endpoints through a corporate proxy (e.g. Zscaler).
# Usage: docker compose build --build-arg CORPORATE_CA_CERT="$(cat your-cert.cer)"
# Leave unset for normal environments — the RUN step is a no-op when empty.
ARG CORPORATE_CA_CERT=""
RUN if [ -n "$CORPORATE_CA_CERT" ]; then \
      echo "$CORPORATE_CA_CERT" > /usr/local/share/ca-certificates/corporate-ca.crt && \
      apk add --no-cache ca-certificates && \
      update-ca-certificates; \
    fi

# Install packages needed for development
RUN apk add --no-cache \
    build-base \
    git \
    pkgconfig \
    curl \
    sqlite-dev \
    sqlite \
    tzdata

# Install application gems
COPY Gemfile Gemfile.lock /rails/
RUN bundle install --gemfile=/rails/Gemfile

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["sh", "-c", "./bin/rails db:prepare && ./bin/rails server -b 0.0.0.0"]
