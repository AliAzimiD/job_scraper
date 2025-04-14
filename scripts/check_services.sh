#!/bin/bash

# Set colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Job Scraper Services Status ===${NC}"
echo

# Check if docker is running
if ! docker info >/dev/null 2>&1; then
  echo -e "${RED}Error: Docker is not running${NC}"
  exit 1
fi

# Check Docker containers
echo -e "${YELLOW}Docker Containers:${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "job_|superset"

echo

# Check specific services
check_service() {
  local service=$1
  local port=$2
  local endpoint=$3
  local name=$4
  
  echo -n "Checking $name on port $port... "
  
  if curl -s "http://localhost:$port$endpoint" -o /dev/null -w "%{http_code}" 2>/dev/null | grep -q "200\|301\|302"; then
    echo -e "${GREEN}OK${NC}"
    return 0
  else
    echo -e "${RED}FAILED${NC}"
    return 1
  fi
}

echo -e "${YELLOW}Service Health Checks:${NC}"
check_service "test_server" "8089" "/" "Test Server"
check_service "admin" "8081" "/admin" "Admin Dashboard"

echo

# Check database
echo -e "${YELLOW}Database Check:${NC}"
if docker exec job_db pg_isready -U jobuser >/dev/null 2>&1; then
  echo -e "Database: ${GREEN}OK${NC}"
else
  echo -e "Database: ${RED}FAILED${NC}"
fi

# Check Redis
echo -e "${YELLOW}Redis Check:${NC}"
if docker exec job_redis redis-cli ping | grep -q "PONG"; then
  echo -e "Redis: ${GREEN}OK${NC}"
else
  echo -e "Redis: ${RED}FAILED${NC}"
fi

echo
echo -e "${YELLOW}=== End of Status Report ===${NC}"

# Make executable
chmod +x "$(dirname "$0")/check_services.sh" 