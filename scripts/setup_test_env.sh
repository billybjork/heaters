#!/bin/bash

# Setup Test Environment for Docker Database
# This script configures the test environment to use the Docker dev database
# Run this before running tests: source scripts/setup_test_env.sh

echo "🐳 Setting up test environment for Docker database..."

# Set test database environment variables to use Docker dev database
export TEST_DB_HOST="localhost"     # Docker container exposed on localhost
export TEST_DB_PORT="5433"          # Docker exposes PostgreSQL on port 5433
export TEST_DB_USER="dev_user"
export TEST_DB_PASSWORD="dev_password"

# We'll use a separate test database on the same Docker instance
export TEST_DB_NAME="heaters_test"

echo "✅ Test environment configured:"
echo "   HOST: $TEST_DB_HOST"
echo "   PORT: $TEST_DB_PORT"
echo "   USER: $TEST_DB_USER" 
echo "   DATABASE: $TEST_DB_NAME"
echo ""
echo "📋 Make sure Docker is running with:"
echo "   docker-compose up -d"
echo ""
echo "🧪 Then run tests with:"
echo "   mix test"

# You can also add this to your shell profile (.bashrc, .zshrc, etc.) for persistence:
# echo "Add these to your shell profile for persistence:"
# echo "export TEST_DB_HOST=\"localhost\""
# echo "export TEST_DB_USER=\"dev_user\""
# echo "export TEST_DB_PASSWORD=\"dev_password\"" 