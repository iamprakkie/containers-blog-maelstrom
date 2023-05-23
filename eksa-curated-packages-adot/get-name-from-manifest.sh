#!/bin/bash
# Function to extract the name from the manifest file
get_name_from_manifest() {
  local manifest_file="$1"
  local name
  while IFS='' read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*name:[[:space:]]*(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      break
    fi
  done < "$manifest_file"
  echo "$name"
}