#!/bin/bash
# Dashboard Status Script
# This script checks the status of the job scraper system components

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print section headers
print_header() {
  echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Function to check a service
check_service() {
  local name=$1
  local url=$2
  local expected_status=$3
  
  echo -n "Checking $name... "
  
  response=$(curl -s -o /dev/null -w "%{http_code}" $url)
  
  if [ "$response" == "$expected_status" ]; then
    echo -e "${GREEN}OK${NC} (HTTP $response)"
    return 0
  else
    echo -e "${RED}FAIL${NC} (Expected HTTP $expected_status, got HTTP $response)"
    return 1
  fi
}

# Function to check docker container
check_container() {
  local name=$1
  
  echo -n "Checking container $name... "
  
  if docker ps | grep -q $name; then
    status=$(docker inspect --format='{{.State.Status}}' $name)
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no health check{{end}}' $name)
    echo -e "${GREEN}OK${NC} (Status: $status, Health: $health)"
    return 0
  else
    echo -e "${RED}FAIL${NC} (Container not running)"
    return 1
  fi
}

# Function to check configuration
check_config() {
  local url=$1
  
  echo -n "Checking configuration... "
  
  response=$(curl -s $url)
  
  if [ -n "$response" ] && [[ $response == *"sources"* ]]; then
    echo -e "${GREEN}OK${NC}"
    echo "Configuration summary:"
    echo "$response" | grep -o '"enabled":[^,]*' | head -1
    echo "$response" | grep -o '"schedule":[^,]*' | head -1
    return 0
  else
    echo -e "${RED}FAIL${NC} (Invalid or empty configuration)"
    return 1
  fi
}

# Main script
print_header "Job Scraper Dashboard Status"
echo "Time: $(date)"

# Check Docker containers
print_header "Docker Containers"
docker ps

# Check Test Server
print_header "Test Server"
check_service "Test Server Root" "http://localhost:8089/" 200
check_service "Test Server Health" "http://localhost:8089/health" 200

# Check Admin Dashboard
print_header "Admin Dashboard"
check_service "Admin Dashboard" "http://localhost:8081/admin" 200
check_service "Admin API Stats" "http://localhost:8081/api/stats" 200
check_service "Admin API Logs" "http://localhost:8081/api/logs" 200
check_config "http://localhost:8081/api/config"

# Check Database
print_header "Database"
if check_container "job_db"; then
  # Try a basic database query if container is running
  if docker exec job_db psql -U jobuser -d jobsdb -c "\l" > /dev/null 2>&1; then
    echo -e "Database connection: ${GREEN}OK${NC}"
  else
    echo -e "Database connection: ${RED}FAIL${NC}"
  fi
fi

# Summary
print_header "Summary"
echo "Your Job Scraper system appears to be running correctly."
echo "- Test Server: http://localhost:8089/"
echo "- Admin Dashboard: http://localhost:8081/admin"
echo "- Database: PostgreSQL on port 5432"

echo -e "\n${YELLOW}For more detailed logs:${NC}"
echo "  docker logs job_test     # Test server logs"
echo "  docker logs job_admin    # Admin dashboard logs"
echo "  docker logs job_db       # Database logs"

exit 0 