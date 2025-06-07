import argparse
import sys
import os
import json
import logging
import importlib
import traceback

# Configure logging to stream to stdout, which Elixir's Port will capture.
# This ensures Python logs appear alongside Elixir logs.
logging.basicConfig(
    stream=sys.stdout, 
    level=logging.INFO, 
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

def main():
    """
    This is the single entrypoint for all Python tasks called by Elixir.
    It uses the task_name argument to dynamically load and run the correct module.
    """
    parser = argparse.ArgumentParser(description="A CLI to run Python tasks for the Heaters app.")
    parser.add_argument("task_name", help="The name of the task module to run (e.g., 'intake', 'splice').")
    parser.add_argument("--args-json", required=True, help="A JSON string containing the arguments for the task.")
    cli_args = parser.parse_args()

    try:
        task_module_name = cli_args.task_name
        # Dynamically import the task module from the `py_tasks` package
        # e.g., if task_name is 'intake', this imports py_tasks.intake
        task_module = importlib.import_module(f"py_tasks.{task_module_name}")
    except ImportError:
        logging.error(f"Error: Could not find or import task module 'py_tasks.{task_module_name}'.")
        sys.exit(1)

    try:
        task_args = json.loads(cli_args.args_json)
    except json.JSONDecodeError:
        logging.error("Error: Invalid JSON provided in --args-json argument.")
        sys.exit(1)

    try:
        # By convention, we expect each module to have a `run_<task_name>` function.
        # e.g., intake.py has run_intake(), splice.py has run_splice()
        task_function_name = f"run_{task_module_name}"
        task_function = getattr(task_module, task_function_name)
        
        # Execute the task, passing the deserialized arguments.
        # The 'environment' kwarg is added for context within the task.
        result = task_function(
            **task_args, 
            environment=os.getenv("APP_ENV", "development")
        )
        
        # On success, print the final result as a single JSON line to stdout.
        # This is how the task signals its result back to Elixir.
        print(json.dumps(result))

    except Exception:
        # On any failure, log the full exception traceback and exit with a non-zero code.
        # This is critical for Oban to correctly mark the job as failed.
        logging.error(f"Task '{task_module_name}' failed with an exception:")
        logging.error(traceback.format_exc())
        sys.exit(1)

if __name__ == "__main__":
    main()