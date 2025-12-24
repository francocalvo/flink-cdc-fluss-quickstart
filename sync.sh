rsync  \
  -avz --exclude=".venv" --exclude='.git' --exclude='node_modules' --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' \
  --exclude='streaming-gradle/.gradle' --exclude='streaming-gradle/lib/build' --exclude='streaming-gradle/build' \
  --exclude='streaming-gradle/lib/.gradle' --exclude='streaming-gradle/lib/bin' \
  /Users/francocalvo/draftea/pocs/streaming/ \
  muad@192.168.1.4:/home/muad/streaming/

