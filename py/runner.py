import argparse
import sys
import os
import json
import logging
import importlib
import traceback

# Add the parent directory to Python path so we can import py
parent_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if parent_dir not in sys.path:
    sys.path.insert(0, parent_dir)

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
    logging.info(f"Python runner started with task: {sys.argv[1] if len(sys.argv) > 1 else 'none'}")
    sys.stdout.flush()
    
    parser = argparse.ArgumentParser(description="A CLI to run various Python tasks")
    parser.add_argument("task_name", help="The name of the task module to run (e.g., 'submit', 'splice').")
    
    # Support both command line JSON and file-based JSON
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--args-json", help="A JSON string containing the arguments for the task.")
    group.add_argument("--args-file", help="Path to a file containing JSON arguments for the task.")
    
    args = parser.parse_args()
    task_module_name = args.task_name
    
    logging.info(f"Successfully parsed arguments: task_name='{task_module_name}'")
    
    # Read task arguments from JSON (either command line or file)
    if args.args_json:
        logging.info("Reading JSON from command line argument")
        try:
            task_args = json.loads(args.args_json)
        except json.JSONDecodeError as e:
            logging.error(f"Failed to parse JSON from command line: {e}")
            sys.exit(1)
    else:
        logging.info(f"Reading JSON from file: {args.args_file}")
        try:
            with open(args.args_file, 'r') as f:
                json_content = f.read()
                logging.info(f"JSON content from file: {json_content}")
                task_args = json.loads(json_content)
        except (FileNotFoundError, json.JSONDecodeError) as e:
            logging.error(f"Failed to read or parse JSON from file {args.args_file}: {e}")
            sys.exit(1)

    try:
        # Dynamically import the task module from the `py.tasks` package
        # e.g., if task_name is 'submit', this imports py.tasks.submit
        task_module = importlib.import_module(f"py.tasks.{task_module_name}")
    except ImportError as e:
        logging.error(f"Error: Could not find or import task module 'py.tasks.{task_module_name}'.")
        logging.error(f"Import error details: {e}")
        logging.error(f"Make sure the module exists and is properly named.")
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
        
        # On success, print the final result as a single JSON line to stdout,
        # prefixed with a token for reliable parsing by Elixir.
        # This is how the task signals its result back to Elixir.
        print(f"FINAL_JSON:{json.dumps(result)}")

    except Exception:
        # On any failure, log the full exception traceback and exit with a non-zero code.
        # This is critical for Oban to correctly mark the job as failed.
        logging.error(f"Task '{task_module_name}' failed with an exception:")
        logging.error(traceback.format_exc())
        sys.exit(1)

if __name__ == "__main__":
    main()