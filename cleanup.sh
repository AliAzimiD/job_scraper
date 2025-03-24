#!/bin/bash

# Colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}===== Job Scraper Cleanup =====${NC}"
echo -e "${RED}WARNING: This will remove all containers, volumes, and networks related to the job scraper.${NC}"
echo -e "${RED}All data will be lost! Make sure you have backed up any important data.${NC}"

read -p "Are you sure you want to continue? (y/n): " confirm
if [[ $confirm != [yY] ]]; then
    echo -e "${GREEN}Cleanup cancelled.${NC}"
    exit 0
fi

echo -e "${YELLOW}Stopping and removing all containers...${NC}"
docker-compose -f docker-compose.dev.yml down --volumes --remove-orphans

echo -e "${YELLOW}Removing any leftover job scraper containers...${NC}"
docker ps -a | grep "job_" | awk '{print $1}' | xargs -r docker rm -f

echo -e "${YELLOW}Removing job scraper volumes...${NC}"
docker volume ls | grep "job_" | awk '{print $2}' | xargs -r docker volume rm

echo -e "${YELLOW}Removing job scraper networks...${NC}"
docker network ls | grep "scraper-network" | awk '{print $1}' | xargs -r docker network rm

echo -e "${YELLOW}Removing job scraper images...${NC}"
docker images | grep "job_scraper" | awk '{print $3}' | xargs -r docker rmi -f

echo -e "${YELLOW}Pruning unused Docker resources...${NC}"
docker system prune -f

echo -e "${GREEN}Cleanup complete!${NC}"
echo -e "${YELLOW}You can now run ./test_locally.sh to start fresh.${NC}" 