#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <METHOD> <URL> [--data <json>] [--data-file <path>]" >&2
  exit 1
fi

METHOD="$1"
URL="$2"
shift 2

DATA=""
DATA_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data)
      DATA="${2:-}"
      shift 2
      ;;
    --data-file)
      DATA_FILE="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${GITLAB_TOKEN:-}" ]]; then
  echo "GITLAB_TOKEN is required" >&2
  exit 1
fi

curl_args=(-sf -X "$METHOD" -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")

if [[ -n "$DATA" ]]; then
  curl_args+=(-H "Content-Type: application/json" -d "$DATA")
elif [[ -n "$DATA_FILE" ]]; then
  curl_args+=(-H "Content-Type: application/json" -d "@${DATA_FILE}")
fi

curl "${curl_args[@]}" "$URL"
