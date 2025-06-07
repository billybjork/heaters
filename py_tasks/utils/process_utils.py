import subprocess
import shutil
import logging
from typing import List, Tuple, Optional, Dict

# Use standard Python logging. The runner.py configures the root logger,
# so any logs created here will be captured and sent to stdout.
logger = logging.getLogger(__name__)

def run_external_command(
    cmd_list: List[str],
    step_name: str = "External Command",
    cwd: Optional[str] = None,
    env: Optional[Dict[str, str]] = None,
) -> Tuple[str, str]:
    """
    Runs an external command using subprocess, logs output, and raises errors.
    This is the core utility for interacting with command-line tools like ffmpeg.

    Args:
        cmd_list: The command and its arguments as a list of strings.
        step_name: A descriptive name for the command step (for logging).
        cwd: The working directory for the command (optional).
        env: A dictionary of environment variables for the command (optional).

    Returns:
        A tuple containing (stdout, stderr) as strings.

    Raises:
        FileNotFoundError: If the command executable is not found.
        subprocess.CalledProcessError: If the command returns a non-zero exit code.
    """
    cmd_str = " ".join(cmd_list)
    logger.info(f"Running {step_name}: {cmd_str}")

    try:
        process = subprocess.Popen(
            cmd_list,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            cwd=cwd,
            env=env,
        )
        stdout, stderr = process.communicate()

        if process.returncode != 0:
            logger.error(
                f"Error during '{step_name}': Command failed with exit code {process.returncode}."
            )
            # Log the full error to help debugging in Oban
            if stderr:
                logger.error(f"STDERR ({step_name}):\n{stderr}")
            if stdout:
                logger.error(f"STDOUT ({step_name}):\n{stdout}")
            raise subprocess.CalledProcessError(
                process.returncode, cmd_list, output=stdout, stderr=stderr
            )

        logger.info(f"'{step_name}' completed successfully.")
        return stdout, stderr

    except FileNotFoundError:
        logger.error(
            f"Error during '{step_name}': Command not found: '{cmd_list[0]}'. Is it installed in the environment?"
        )
        raise
    except Exception as e:
        logger.error(
            f"An unexpected error occurred during '{step_name}': {e}", exc_info=True
        )
        raise


def run_ffmpeg_command(
    cmd_list: List[str],
    step_name: str = "ffmpeg command",
    cwd: Optional[str] = None,
    ffmpeg_executable: Optional[str] = None,
) -> None:
    """
    A specific wrapper for running ffmpeg commands. It raises an error on failure
    but does not return any output, as ffmpeg output is usually not parsed.
    """
    ffmpeg_path = ffmpeg_executable or shutil.which("ffmpeg")
    if not ffmpeg_path:
        raise FileNotFoundError("FFmpeg executable not found in PATH.")

    # Prepend the ffmpeg path if the command doesn't already include it
    final_cmd = cmd_list if cmd_list[0] == ffmpeg_path else [ffmpeg_path] + cmd_list

    run_external_command(final_cmd, step_name, cwd=cwd)
    return


def run_ffprobe_command(
    cmd_list: List[str],
    step_name: str = "ffprobe command",
    cwd: Optional[str] = None,
    ffprobe_executable: Optional[str] = None,
) -> Tuple[str, str]:
    """
    A specific wrapper for running ffprobe commands. It returns the stdout and stderr
    so that its output (e.g., video duration, FPS) can be parsed by the calling task.
    """
    ffprobe_path = ffprobe_executable or shutil.which("ffprobe")
    if not ffprobe_path:
        raise FileNotFoundError("ffprobe executable not found in PATH.")

    # Prepend the ffprobe path if the command doesn't already include it
    final_cmd = cmd_list if cmd_list[0] == ffprobe_path else [ffprobe_path] + cmd_list

    return run_external_command(final_cmd, step_name, cwd=cwd)