import subprocess
import shutil
from prefect import get_run_logger

FFMPEG_PATH = "ffmpeg"  # Default, can be overridden by tasks if necessary

def run_external_command(cmd_list: list[str], step_name: str = "External Command", cwd: str | None = None, env: dict | None = None):
    """
    Runs an external command using subprocess, logs output, and raises errors.

    Args:
        cmd_list: The command and its arguments as a list of strings.
        step_name: A descriptive name for the command step (for logging).
        cwd: The working directory for the command (optional).
        env: A dictionary of environment variables to set for the command (optional).

    Returns:
        True if the command was successful.

    Raises:
        FileNotFoundError: If the command executable is not found.
        subprocess.CalledProcessError: If the command returns a non-zero exit code.
        Exception: For other unexpected errors during execution.
    """
    logger = get_run_logger()
    cmd_str = ' '.join(cmd_list)
    logger.info(f"Running {step_name}: {cmd_str}")

    try:
        process = subprocess.Popen(
            cmd_list,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding='utf-8',
            errors='replace',
            cwd=cwd,
            env=env
        )
        stdout, stderr = process.communicate()

        if process.returncode != 0:
            logger.error(f"Error during '{step_name}': Command failed with exit code {process.returncode}.")
            stderr_to_log = stderr if len(stderr) < 2000 else stderr[:2000] + "... (truncated)"
            stdout_to_log = stdout if len(stdout) < 2000 else stdout[:2000] + "... (truncated)"
            if stderr_to_log: logger.error(f"STDERR ({step_name}):\n{stderr_to_log}")
            if stdout_to_log: logger.error(f"STDOUT ({step_name}):\n{stdout_to_log}")
            raise subprocess.CalledProcessError(process.returncode, cmd_list, output=stdout, stderr=stderr)
        else:
            if stdout and stdout.strip():
                 stdout_snippet = stdout[:500] + ("..." if len(stdout) > 500 else "")
                 logger.debug(f"STDOUT ({step_name} - snippet):\n{stdout_snippet}")
            if stderr and stderr.strip():
                 stderr_snippet = stderr[:500] + ("..." if len(stderr) > 500 else "")
                 logger.info(f"STDERR ({step_name} - snippet, possibly informational):\n{stderr_snippet}")
            logger.info(f"'{step_name}' completed successfully.")
        return True

    except FileNotFoundError:
        logger.error(f"Error during '{step_name}': Command not found: '{cmd_list[0]}'. Is it installed and in PATH?")
        raise
    except subprocess.CalledProcessError:
        raise
    except Exception as e:
        logger.error(f"An unexpected error occurred during '{step_name}': {e}", exc_info=True)
        raise

def run_ffmpeg_command(cmd_list: list[str], step_name: str = "ffmpeg command", cwd: str | None = None, ffmpeg_executable: str | None = None):
    """
    Runs an ffmpeg command using the generic run_external_command.
    """
    logger = get_run_logger()
    actual_ffmpeg_path = ffmpeg_executable or FFMPEG_PATH or "ffmpeg"
    final_cmd_list = list(cmd_list) # Make a copy to modify
    if not final_cmd_list or final_cmd_list[0] != actual_ffmpeg_path:
        # If the first element is a path and looks like ffmpeg, trust it.
        # Otherwise, prepend the actual_ffmpeg_path.
        if final_cmd_list and ("ffmpeg" in final_cmd_list[0] or "ffprobe" in final_cmd_list[0]): # Simple check
             pass # Assume user provided full path in cmd_list[0]
        else:
            logger.debug(f"Prepending ffmpeg path '{actual_ffmpeg_path}' to command list for '{step_name}'. Original command started with: '{final_cmd_list[0] if final_cmd_list else ''}'")
            final_cmd_list = [actual_ffmpeg_path] + final_cmd_list


    # Check if ffmpeg is available
    if not shutil.which(final_cmd_list[0]):
        logger.error(f"FFmpeg executable '{final_cmd_list[0]}' not found in PATH or at specified location.")
        raise FileNotFoundError(f"FFmpeg executable '{final_cmd_list[0]}' not found.")

    return run_external_command(final_cmd_list, step_name, cwd=cwd)

def run_ffprobe_command(cmd_list: list[str], step_name: str = "ffprobe command", cwd: str | None = None, ffprobe_executable: str | None = None):
    """
    Runs an ffprobe command and returns its stdout and stderr.
    """
    logger = get_run_logger()
    actual_ffprobe_path = ffprobe_executable or "ffprobe"
    final_cmd_list = list(cmd_list) # Make a copy to modify
    if not final_cmd_list or final_cmd_list[0] != actual_ffprobe_path:
        if final_cmd_list and "ffprobe" in final_cmd_list[0]:
            pass
        else:
            logger.debug(f"Prepending ffprobe path '{actual_ffprobe_path}' to command list for '{step_name}'. Original command started with: '{final_cmd_list[0] if final_cmd_list else ''}'")
            final_cmd_list = [actual_ffprobe_path] + final_cmd_list
    
    if not shutil.which(final_cmd_list[0]):
        logger.error(f"ffprobe executable '{final_cmd_list[0]}' not found.")
        raise FileNotFoundError(f"ffprobe executable '{final_cmd_list[0]}' not found.")
    
    logger.info(f"Running {step_name}: {' '.join(final_cmd_list)}")
    try:
        process = subprocess.Popen(
            final_cmd_list,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding='utf-8',
            errors='replace',
            cwd=cwd
        )
        stdout, stderr = process.communicate()

        if process.returncode != 0:
            logger.error(f"Error during '{step_name}': Command failed with exit code {process.returncode}.")
            stderr_to_log = stderr if len(stderr) < 2000 else stderr[:2000] + "... (truncated)"
            if stderr_to_log: logger.error(f"STDERR ({step_name}):\n{stderr_to_log}")
            raise subprocess.CalledProcessError(process.returncode, final_cmd_list, output=stdout, stderr=stderr)
        
        if stderr and stderr.strip():
            stderr_snippet = stderr[:500] + ("..." if len(stderr) > 500 else "")
            logger.info(f"STDERR ({step_name} - snippet, possibly informational):\n{stderr_snippet}")
        logger.info(f"'{step_name}' completed successfully.")
        return stdout, stderr # Return stdout and stderr for parsing

    except FileNotFoundError:
        logger.error(f"Error during '{step_name}': Command not found: '{final_cmd_list[0]}'.")
        raise
    except subprocess.CalledProcessError:
        raise
    except Exception as e:
        logger.error(f"An unexpected error occurred during '{step_name}': {e}", exc_info=True)
        raise