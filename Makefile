# Makefile

.PHONY: build start stop logs restart clean dev test lint format debug shell

# Production commands
build:
	docker-compose build

start:
	docker-compose up -d

stop:
	docker-compose down

logs:
	docker-compose logs -f

restart:
	docker-compose restart

clean:
	docker-compose down -v
	sudo rm -rf job_data/*

# Development commands
dev:
	docker-compose -f docker-compose.dev.yml up --build

dev-db:
	docker-compose -f docker-compose.dev.yml up -d db_dev

test:
	docker-compose -f docker-compose.dev.yml run --rm scraper pytest

lint:
	docker-compose -f docker-compose.dev.yml run --rm scraper flake8 src tests

format:
	docker-compose -f docker-compose.dev.yml run --rm scraper black src tests
	docker-compose -f docker-compose.dev.yml run --rm scraper isort src tests

debug:
	docker-compose -f docker-compose.dev.yml run --rm -p 5678:5678 scraper python -m debugpy --listen 0.0.0.0:5678 main.py

shell:
	docker-compose -f docker-compose.dev.yml run --rm scraper ipython
