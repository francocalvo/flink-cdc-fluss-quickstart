nix-shell -p \
      python312Packages.pandas \
      python312Packages.sqlalchemy \
      python312Packages.psycopg2 \
      python312Packages.faker \
      --run "python ./postgres-source/gen_data.py $@"
