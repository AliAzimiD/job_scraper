#!/bin/bash

# docker_manage.sh
case "$1" in
    "build")
        docker-compose build
        ;;
    "start")
        docker-compose up -d
        ;;
    "stop")
        docker-compose down
        ;;
    "logs")
        docker-compose logs -f
        ;;
    "restart")
        docker-compose restart
        ;;
    "clean")
        docker-compose down -v
        ;;
    *)
        echo "Usage: $0 {build|start|stop|logs|restart|clean}"
        exit 1
        ;;
esac
