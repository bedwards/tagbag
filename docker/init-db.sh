#!/bin/bash
set -e

# Create databases for each service plus TagBag's own coordination layer
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE gitea;
    CREATE DATABASE woodpecker;
    CREATE DATABASE tagbag;
EOSQL
