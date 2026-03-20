#!/usr/bin/env bash
nix-shell -p \
    python312Packages.psycopg2 \
    python312Packages.faker \
    --run "python ./postgres-source/gen_data.py $*"
