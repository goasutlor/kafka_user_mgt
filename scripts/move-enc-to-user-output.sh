#!/usr/bin/env bash
# Move .enc files from repo root into user_output/ (one-time on server)
ROOT="${1:-.}"
if [ ! -d "$ROOT" ]; then
  echo "Usage: $0 [ROOT_DIR]"
  echo "  ROOT_DIR = path to kafka-usermgmt (default: current dir)"
  exit 1
fi
mkdir -p "$ROOT/user_output"
moved=0
for f in "$ROOT"/*.enc; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  if [ -f "$ROOT/user_output/$name" ]; then
    echo "Skip (exists in user_output): $name"
  else
    mv "$f" "$ROOT/user_output/" && echo "Moved: $name" && moved=$((moved+1))
  fi
done
echo "Done. Moved $moved file(s) to user_output/"
