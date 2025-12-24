rsync  \
  -avz --exclude=".venv" --exclude='.git' --exclude='node_modules' --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' \
  /Users/francocalvo/draftea/pocs/streaming/ \
  muad@192.168.1.4:/home/muad/streaming/

