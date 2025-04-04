# 🔍 Job Scraper System Architecture

This document provides a comprehensive overview of the Job Scraper system architecture, components, data flow, and organization to help developers understand the system.

## 📑 Table of Contents

- [System Architecture Overview](#system-architecture-overview)
- [Data Flow Diagram](#data-flow-diagram)
- [Scraping Functions](#scraping-functions)
- [Directory Structure](#directory-structure)
- [Database Schema and Relationships](#database-schema-and-relationships)
- [Key System Features](#key-system-features)
- [Key Files and Their Purpose](#key-files-and-their-purpose)
- [Service Access Points](#service-access-points)
- [Database Connection URIs](#database-connection-uris)

---

## 🏗️ System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Job Scraper System Architecture                  │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                        Docker Container Services                     │
├───────────────┬───────────────┬───────────────┬───────────────┬─────┴─────────┐
│  job_scraper  │    job_db     │  job_pgadmin  │  job_superset │   job_redis   │
│   (Scraper    │  (PostgreSQL  │   (PgAdmin    │   (Superset   │    (Redis     │
│   Application)│    Database)  │      UI)      │   Dashboard)  │    Cache)     │
└───────┬───────┴───────┬───────┴───────┬───────┴───────┬───────┴───────┬───────┘
        │               │               │               │               │
        │  ┌────────────▼──────────────▼──────────────┐│               │
        │  │          Docker Network (scraper-network)◄┘               │
        │  └────────────▲──────────────▲──────────────┘                │
        │               │               │                               │
┌───────▼───────┐      │         ┌─────▼─────┐                 ┌───────▼───────┐
│  API Service  │      │         │   Web UI  │                 │  Cron Jobs    │
│  Port: 8081   │      │         │           │                 │               │
└───────────────┘      │         └───────────┘                 └───────────────┘
                       │
┌──────────────────────▼───────────────────────┐
│              Database Structure              │
├───────────────────┬─────────────────────────┤
│  Normalized Tables│    Partitioned Tables    │
├───────────────────┼─────────────────────────┤
│ - companies       │ - jobs_partitioned      │
│ - job_tags        │   (by month)            │
│ - jobs_tags       │ - job_batches_partitioned│
│ - job_categories  │                         │
│ - jobs_categories │                         │
│ - locations       │                         │
│ - job_locations   │                         │
│ - work_types      │                         │
│ - job_work_types  │                         │
└───────────────────┴─────────────────────────┘
        │                       │
        ▼                       ▼
┌───────────────────┐  ┌─────────────────────┐
│ Materialized Views│  │ Database Functions  │
├───────────────────┤  ├─────────────────────┤
│- job_stats_by_company│- insert_job()       │
│- job_stats_by_tag   │- update_job_batch()  │
│- job_stats_by_category│- get_jobs()        │
│- job_stats_by_location│- jobs_view_insert_trigger() │
│- tag_cooccurrence   │- create_future_job_partitions()│
│- category_tag_relationship│                 │
│- job_posting_trends │                       │
└───────────────────┘  └─────────────────────┘
```

---

## 🔄 Data Flow Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│                      Job Scraper Data Flow                          │
└────────────────────────────────────────────────────────────────────┘

┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Source    │    │ Job Scraper │    │ PostgreSQL  │    │   Superset  │
│  Websites   │───►│  Container  │───►│  Database   │───►│  Dashboard  │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
       │                  │                  │                  │
       │                  │                  │                  │
       ▼                  ▼                  ▼                  ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Raw HTML   │    │ Parsed Job  │    │ Normalized  │    │ Interactive │
│   Content   │    │    Data     │    │  Schema     │    │ Visualizat. │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

---

## 🤖 Scraping Functions

```
┌───────────────────────────────────────────────────────────────────┐
│                   Job Scraper Functions Workflow                   │
└───────────────────────────────────────────────────────────────────┘

┌─────────────────┐       ┌─────────────────────┐
│ ScheduleManager │◄──────┤ CronService         │
│ - schedule_jobs │       │ - register_jobs     │
│ - run_job       │       │ - start             │
└───────┬─────────┘       └─────────────────────┘
        │
        ▼
┌───────────────────────┐  ┌─────────────────────┐
│ ScraperManager        │  │ ConfigManager       │
│ - init_scrapers       │◄─┤ - load_config       │
│ - run_scraper         │  │ - get_sources       │
└───────┬───────────────┘  └─────────────────────┘
        │
        ▼
┌───────────────────────┐  ┌─────────────────────┐
│ Scraper (Base Class)  │  │ ScraperFactory      │
│ - fetch_page          │◄─┤ - create_scraper    │
│ - parse_job_listings  │  │ - get_scraper_class │
│ - extract_details     │  └─────────────────────┘
└───────┬───────────────┘
        │
        ├───────────┬───────────┬───────────┐
        ▼           ▼           ▼           ▼
┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐
│JobSiteA   │ │JobSiteB   │ │JobSiteC   │ │JobSiteD   │
│Scraper    │ │Scraper    │ │Scraper    │ │Scraper    │
└────┬──────┘ └────┬──────┘ └────┬──────┘ └────┬──────┘
     │             │             │             │
     └─────────────┴─────────────┴─────────────┘
                   │
                   ▼
┌──────────────────────────┐     ┌────────────────────┐
│ DataProcessor            │     │ DataNormalizer     │
│ - process_job_data       │────►│ - normalize_job    │
│ - deduplicate            │     │ - extract_entities │
│ - validate               │     └────────┬───────────┘
└──────────────────────────┘              │
                                          ▼
┌──────────────────────────┐     ┌────────────────────┐
│ DatabaseManager          │     │ BatchProcessor     │
│ - insert_jobs_normalized │◄────┤ - create_batch     │
│ - update_job_batch       │     │ - complete_batch   │
│ - get_job_count          │     │ - process_jobs     │
└──────────────────────────┘     └────────────────────┘
```

---

## 📁 Directory Structure

```
┌─────────────────────────────────────────────────────────────────┐
│                      Directory Structure                         │
└─────────────────────────────────────────────────────────────────┘

/root/karchi/job_scraper/
├── archive/           ├── migrations/        ├── scripts/
│   └── (old files)    │   ├── *.sql         │   ├── cleanup.sh
│                      │   ├── *.py          │   ├── run-migrations.sh
├── backups/           │   └── README.md     │   ├── setup-git.sh
│   └── jobsdb_*.sql   │                      │   └── configure_git.sh
│                      ├── init-db/           │
├── config/            │   ├── 01-init.sql   ├── secrets/
│   └── api_config.yaml│   └── 02-schema-update.sh  └── (password files)
│                      │
├── docker/            ├── superset/          ├── src/
│   └── compose files  │   ├── Dockerfile     │   └── (source code)
│                      │   └── superset_config.py
├── job_data/          │                      │
│                      ├── docker-compose.yml │
└── install.sh         └── (other root files)
```

---

## 🗃️ Database Schema and Relationships

```
┌───────────────────────────────────────────────────────────────────┐
│                    Database Schema Relationships                   │
└───────────────────────────────────────────────────────────────────┘

┌───────────┐            ┌───────────────┐
│ companies ◄────────────┤ jobs_partitioned│
└───────────┘            └─┬─────────┬───┬─┘
                           │         │   │
                           │         │   │
┌───────────┐    ┌─────────┘  ┌─────▼───▼┐    ┌───────────┐
│ job_tags  ◄────┴─►jobs_tags││  job_batches│◄──┤job_batches_partitioned│
└─────┬─────┘              └─┬─▲────────┘    └───────────┘
      │                      │ │
      │                      │ │
┌─────▼─────┐              ┌─▼─┴────────┐
│category_tag│             │job_locations│
│relationship│             └──┬──▲──────┘
└───────────┘                 │  │
                              │  │
┌───────────┐    ┌────────────┘  │      ┌───────────┐
│job_categories◄──┴►jobs_categories     │work_types◄─┐
└───────────┘                │          └───────────┘│
                          ┌──▼──┐                    │
                          │locations│       ┌────────▼────┐
                          └──────┘         │job_work_types│
                                           └──────────────┘
```

---

## ⚙️ Key System Features

```
┌─────────────────────────────────────────────────────────────┐
│                     Key System Features                      │
└─────────────────────────────────────────────────────────────┘

┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│Schema Versioning│  │Table Partitioning│  │  Materialized   │
│ Version 1: Base │  │- Monthly partitions│ │     Views      │
│ Version 2: Normalized│- Automatic creation│- Auto-refreshing│
└─────────────────┘  └─────────────────┘  └─────────────────┘

┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│   Job Scraper   │  │  Authentication  │  │   Installation  │
│- API endpoints  │  │- Database access │  │- Docker setup   │
│- Cron scheduling│  │- Superset users  │  │- Migration scripts│
│- Error handling │  │- Git integration │  │- Data initialization│
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

---

## 📄 Key Files and Their Purpose

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Defines all services and their relationships |
| `install.sh` | Main installation script for the entire system |
| `migrations/*.sql` | SQL scripts for database structure and data migration |
| `superset/superset_config.py` | Configuration for Superset dashboard |
| `init-db/02-schema-update.sh` | Database schema initialization during startup |
| `scripts/setup_git.sh` | Interactive Git configuration |
| `scripts/configure_git.sh` | Non-interactive Git configuration |
| `scripts/cleanup.sh` | Removes all Docker resources |

---

## 🔌 Service Access Points

| Service | URL | Default Credentials |
|---------|-----|---------------------|
| Job Scraper API | http://localhost:8081 | N/A |
| PgAdmin | http://localhost:5050 | Email: admin@example.com<br>Password: admin_password |
| Superset | http://localhost:8088 | Username: admin<br>Password: admin_password |
| PostgreSQL | localhost:5432 | Username: jobuser<br>Password: jobuser_password |

---

## 🔗 Database Connection URIs

### SQLAlchemy URI for Superset
```
postgresql+psycopg2://jobuser:jobuser_password@db:5432/jobsdb
```

### External Connection URI
```
postgresql+psycopg2://jobuser:jobuser_password@localhost:5432/jobsdb
``` 