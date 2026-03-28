#!/bin/bash
set -e

# Create databases for each service (Plane has its own, Gitea and Woodpecker get theirs)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE gitea;
    CREATE DATABASE woodpecker;
EOSQL
