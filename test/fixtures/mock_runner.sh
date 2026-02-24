#!/bin/sh

task_name="${1:-}"
if [ "$#" -gt 0 ]; then
  shift
fi

args_file=""
result_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --args-file)
      args_file="$2"
      shift 2
      ;;
    --result-file)
      result_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

echo "mock runner task=$task_name"

case "$task_name" in
  success_json)
    echo "processing args from $args_file"
    printf '%s' '{"status":"ok","task":"success_json"}' > "$result_file"
    exit 0
    ;;
  missing_result)
    echo "intentionally not writing result file"
    exit 0
    ;;
  invalid_json)
    echo "writing malformed json"
    printf '%s' '{"status":' > "$result_file"
    exit 0
    ;;
  failure)
    echo "failing task output line"
    exit 1
    ;;
  sleep_timeout)
    echo "sleeping to trigger timeout"
    sleep 1
    exit 0
    ;;
  *)
    echo "unknown task: $task_name"
    exit 2
    ;;
esac
