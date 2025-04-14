#!/bin/bash
# Service Management Script
# This script helps manage the job scraper services

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Project root directory
PROJECT_ROOT="/root/karchi/job_scraper"
DOCKER_COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yml"

# Function to print section headers
print_header() {
  echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Function to print usage information
print_usage() {
  echo "Usage: $0 [OPTION] [SERVICE]"
  echo "Options:"
  echo "  start     Start services"
  echo "  stop      Stop services"
  echo "  restart   Restart services"
  echo "  status    Show status of services"
  echo "  logs      Show logs of services"
  echo "  clean     Clean up containers, networks, and optionally volumes"
  echo ""
  echo "Services:"
  echo "  all       All services (default)"
  echo "  test      Test server only"
  echo "  admin     Admin dashboard only"
  echo "  db        Database only"
  echo ""
  echo "Examples:"
  echo "  $0 start           # Start all services"
  echo "  $0 logs test       # Show logs of test server"
  echo "  $0 restart admin   # Restart admin service"
  echo "  $0 clean --volumes # Clean up including volumes"
}

# Function to ensure docker-compose file exists
check_docker_compose() {
  if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
    echo -e "${RED}Error: Docker Compose file not found at $DOCKER_COMPOSE_FILE${NC}"
    exit 1
  fi
}

# Function to check if Docker is running
check_docker() {
  if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}Error: Docker is not running${NC}"
    exit 1
  fi
}

# Function to run docker-compose commands
run_docker_compose() {
  local command=$1
  local service=$2
  
  cd "$PROJECT_ROOT"
  
  case "$command" in
    start)
      echo -e "${YELLOW}Starting $service services...${NC}"
      docker-compose up -d $service
      ;;
    stop)
      echo -e "${YELLOW}Stopping $service services...${NC}"
      docker-compose stop $service
      ;;
    restart)
      echo -e "${YELLOW}Restarting $service services...${NC}"
      docker-compose restart $service
      ;;
    status)
      echo -e "${YELLOW}Status of $service services:${NC}"
      docker-compose ps $service
      ;;
    logs)
      echo -e "${YELLOW}Logs of $service services:${NC}"
      docker-compose logs $service
      ;;
    clean)
      if [ "$service" == "--volumes" ]; then
        echo -e "${YELLOW}Cleaning up containers, networks, and volumes...${NC}"
        docker-compose down -v
      else
        echo -e "${YELLOW}Cleaning up containers and networks...${NC}"
        docker-compose down
      fi
      ;;
    *)
      echo -e "${RED}Unknown command: $command${NC}"
      print_usage
      exit 1
      ;;
  esac
}

# Main script
if [ $# -lt 1 ]; then
  print_usage
  exit 1
fi

# Parse command-line arguments
command=$1
service=${2:-"all"}

# Check environment
check_docker
check_docker_compose

# Execute command
case "$service" in
  all)
    run_docker_compose "$command" ""
    ;;
  test|job_test)
    run_docker_compose "$command" "test"
    ;;
  admin|job_admin)
    run_docker_compose "$command" "admin"
    ;;
  db|job_db)
    run_docker_compose "$command" "db"
    ;;
  --volumes)
    if [ "$command" == "clean" ]; then
      run_docker_compose "$command" "$service"
    else
      echo -e "${RED}Invalid service: $service${NC}"
      print_usage
      exit 1
    fi
    ;;
  *)
    echo -e "${RED}Invalid service: $service${NC}"
    print_usage
    exit 1
    ;;
esac

exit 0 