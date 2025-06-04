# Provides SYNCHRONOUS database utilities using psycopg2 (suitable for Prefect tasks)
# Connects to the APPLICATION database.

from __future__ import annotations
import sys
import os
import time
import logging
from typing import List, Tuple, Dict, Any, Optional, TYPE_CHECKING
from pathlib import Path
from dotenv import load_dotenv
import threading

import psycopg2
from psycopg2 import sql, pool
from psycopg2.extras import RealDictCursor
from psycopg2.extensions import connection as PgConnection
from prefect import get_run_logger

# --- Local Imports ---
try:
    from config import get_database_url
except ImportError:
    # Fallback for local testing if config.py is not directly in sys.path
    # This assumes a certain project structure.
    sys_path_modified = False
    try:
        project_root_for_config = Path(__file__).resolve().parent.parent # backend/
        if str(project_root_for_config) not in sys.path:
            sys.path.insert(0, str(project_root_for_config))
            sys_path_modified = True
        from config import get_database_url
    except ImportError as e:
        print(f"ERROR importing get_database_url from config in sync_db.py: {e}")
        def get_database_url(environment: str, logger=None) -> str:
            raise NotImplementedError("Dummy get_database_url")
    finally:
        if sys_path_modified: # Clean up sys.path if we modified it
            sys.path.pop(0)


# --- Configuration ---
log = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)


# --- Pool Configuration ---
if TYPE_CHECKING: # Prevent runtime error with ThreadedConnectionPool not being generic
    Psycopg2PoolType = pool.ThreadedConnectionPool
else:
    Psycopg2PoolType = pool.ThreadedConnectionPool

_env_pools: Dict[str, Psycopg2PoolType] = {} # Stores pools keyed by environment name
_pool_locks: Dict[str, threading.Lock] = {} # Locks for each environment's pool initialization
_initialized_flags: Dict[str, bool] = {} # Flags for each environment's pool initialization

MIN_POOL_CONN = int(os.getenv("PSYCOPG2_MIN_POOL", 2))
MAX_POOL_CONN = int(os.getenv("PSYCOPG2_MAX_POOL", 10))


# ─────────────────────────────────────────── Pool Management ───────────────────────────────────────────

def initialize_db_pool(environment: str) -> None:
    """Initializes the psycopg2 ThreadedConnectionPool for a specific environment."""
    global _env_pools, _pool_locks, _initialized_flags
    task_log = get_run_logger() or log # Use Prefect logger if available

    # Get or create lock for this environment
    if environment not in _pool_locks:
        _pool_locks[environment] = threading.Lock()
    
    env_lock = _pool_locks[environment]

    with env_lock: # Ensure thread-safe initialization for each environment's pool
        if _initialized_flags.get(environment, False) and _env_pools.get(environment) is not None:
            task_log.debug(f"Pool for environment '{environment}' already initialized.")
            return

        task_log.info(f"Initializing DB pool for environment: '{environment}'...")
        
        try:
            database_url_for_env = get_database_url(environment, logger=task_log)
        except ValueError as e:
            task_log.critical(f"FATAL ERROR: Could not get DATABASE_URL for environment '{environment}'. {e}")
            raise ConnectionError(f"DATABASE_URL missing for '{environment}' pool initialization") from e

        log_url_display = database_url_for_env.split('@')[-1] if '@' in database_url_for_env else database_url_for_env
        task_log.info(f"Creating psycopg2 ThreadedConnectionPool for '{environment}' APP DB ({log_url_display})... (Min: {MIN_POOL_CONN}, Max: {MAX_POOL_CONN})")
        
        try:
            current_pool = psycopg2.pool.ThreadedConnectionPool(
                MIN_POOL_CONN,
                MAX_POOL_CONN,
                dsn=database_url_for_env,
                application_name=f"prefect_worker_{environment}"
            )
            
            # Test connection
            conn_test: Optional[PgConnection] = None
            try:
                conn_test = current_pool.getconn()
                with conn_test.cursor() as cur_test:
                    cur_test.execute("SELECT version();")
                    version = cur_test.fetchone()
                    task_log.info(f"Psycopg2 pool for '{environment}' ready. Connected to APP DB version: {version[0][:25]}...")
                _env_pools[environment] = current_pool
                _initialized_flags[environment] = True
            except Exception as test_err:
                task_log.error(f"Psycopg2 pool for '{environment}' created, but connection test failed: {test_err}", exc_info=True)
                if current_pool:
                    current_pool.closeall()
                _initialized_flags[environment] = False
                if environment in _env_pools: del _env_pools[environment] # Clean up
                raise ConnectionError(f"Sync DB pool connection test failed for '{environment}'") from test_err
            finally:
                if conn_test and current_pool: # Ensure pool exists before putconn
                    current_pool.putconn(conn_test)

        except (psycopg2.OperationalError, psycopg2.pool.PoolError, Exception) as e:
            task_log.critical(f"FATAL ERROR: Failed to create psycopg2 pool for '{environment}' APP DB: {e}", exc_info=True)
            _initialized_flags[environment] = False
            if environment in _env_pools: del _env_pools[environment]
            raise ConnectionError(f"Could not initialize sync DB pool for '{environment}'") from e

def get_db_connection(environment: str, cursor_factory=None) -> PgConnection:
    """
    Gets a synchronous connection from the pool for the specified environment.
    Initializes pool for the environment if needed. Retries on PoolError.
    """
    task_log = get_run_logger() or log

    if not _initialized_flags.get(environment, False) or _env_pools.get(environment) is None:
        task_log.info(f"Sync DB pool for '{environment}' not initialized. Attempting initialization...")
        initialize_db_pool(environment)

    current_pool = _env_pools.get(environment)
    if current_pool is None:
        task_log.error(f"Sync DB pool for '{environment}' is still None after initialization attempt.")
        raise ConnectionError(f"Failed to initialize or get sync DB pool for '{environment}'.")

    retries = 3
    delay = 0.5
    for attempt in range(retries):
        try:
            conn = current_pool.getconn()
            if cursor_factory: # Only set if explicitly provided
                conn.cursor_factory = cursor_factory
            task_log.debug(f"Acquired sync DB connection for '{environment}' (ID: {conn.info.backend_pid}). Cursor factory: {cursor_factory}")
            return conn
        except psycopg2.pool.PoolError as e:
            task_log.warning(f"Could not get connection from '{environment}' pool (Attempt {attempt + 1}/{retries}): {e}. Retrying in {delay}s...")
            if attempt == retries - 1:
                task_log.error(f"Max retries reached trying to get connection from '{environment}' pool.", exc_info=True)
                raise ConnectionError(f"Could not acquire sync DB connection from '{environment}' pool after {retries} attempts") from e
            time.sleep(delay)
            delay *= 2
        except Exception as e:
            task_log.error(f"Unexpected error getting connection from '{environment}' pool: {e}", exc_info=True)
            raise ConnectionError(f"Unexpected error acquiring sync DB connection for '{environment}'") from e
    
    # Should be unreachable
    raise ConnectionError(f"Failed to acquire sync DB connection from '{environment}' (logic error).")


def release_db_connection(conn: PgConnection, environment: str) -> None:
    """Releases a synchronous connection back to the appropriate environment's pool."""
    task_log = get_run_logger() or log
    current_pool = _env_pools.get(environment)

    if current_pool and conn:
        conn.cursor_factory = None # Reset cursor factory
        try:
            current_pool.putconn(conn)
            task_log.debug(f"Released sync DB connection for '{environment}' (ID: {conn.info.backend_pid}) back to pool.")
        except (psycopg2.pool.PoolError, Exception) as e:
            task_log.error(f"Error releasing sync DB connection for '{environment}' (ID: {conn.info.backend_pid}): {e}", exc_info=True)
    elif not current_pool:
        task_log.warning(f"No pool found for environment '{environment}' upon releasing connection. Connection may be closed directly.")
        if conn and not conn.closed:
            try: conn.close()
            except Exception as e_close: task_log.error(f"Error closing unpooled connection for '{environment}': {e_close}")
    elif not conn:
        task_log.warning(f"Attempted to release a None connection for environment '{environment}'.")


def close_all_db_pools() -> None:
    """Closes all connections in all environment-specific synchronous pools."""
    global _env_pools, _initialized_flags, _pool_locks
    task_log = get_run_logger() or log
    
    all_environments = list(_env_pools.keys()) # Get keys before iteration as dict might change
    task_log.info(f"Closing all psycopg2 ThreadedConnectionPools for environments: {all_environments}...")

    for env_name in all_environments:
        env_lock = _pool_locks.get(env_name) # Get specific lock
        if env_lock:
            with env_lock: # Acquire lock before modifying this environment's pool
                pool_to_close = _env_pools.get(env_name)
                if pool_to_close:
                    task_log.info(f"Closing pool for environment '{env_name}'...")
                    try:
                        pool_to_close.closeall()
                        task_log.info(f"Pool for '{env_name}' closed.")
                    except Exception as e:
                        task_log.error(f"Error closing psycopg2 pool for '{env_name}': {e}", exc_info=True)
                    finally:
                        if env_name in _env_pools: del _env_pools[env_name]
                        if env_name in _initialized_flags: _initialized_flags[env_name] = False
                else:
                    task_log.debug(f"No active pool found for '{env_name}' to close.")
        else:
            # This case should ideally not happen if locks are created consistently
            task_log.warning(f"No lock found for environment '{env_name}' during close_all_db_pools. Pool might not be properly managed.")

    # Clear the dictionaries after attempting to close all
    _env_pools.clear()
    _initialized_flags.clear()
    # _pool_locks can be cleared or kept if re-initialization is expected. For full cleanup, clear:
    _pool_locks.clear()
    task_log.info("Finished closing all environment-specific DB pools.")

# ─────────────────────────────────── Application Helper Functions ────────────────────────────────────
# These functions interact with the application schema (source_videos, clips) using the sync pool.

def get_all_pending_work(environment: str, limit_per_stage: int = 50, max_retries: int = 3) -> List[Dict[str, Any]]:
    """
    Fetches all pending work items from the database for a given environment,
    respecting a limit per stage and a maximum retry count.

    Args:
        environment: The database environment ('development' or 'production').
        limit_per_stage: Maximum number of items to fetch for each stage.
        max_retries: Maximum number of retries an item can have before being ignored.

    Returns:
        A list of dictionaries, each representing a work item with 'id' and 'stage'.
    """
    logger = get_run_logger() or log
    all_work_items = []
    conn = None

    # Define stages and their corresponding queries
    # Each query now includes a check for retry_count
    stages_config = {
        "intake": {
            "table": "source_videos",
            "states": "('new', 'download_failed')",
            "order_by": "updated_at ASC",
            "id_col": "id"
        },
        "splice": {
            "table": "source_videos",
            "states": "('downloaded', 'splicing_failed')",
            "order_by": "updated_at ASC",
            "id_col": "id"
        },
        "pending_sprite_generation": {
            "table": "clips",
            "states": "('pending_sprite_generation')",
            "order_by": "inserted_at ASC",
            "id_col": "id"
        },
        "post_review": {
            "table": "clips",
            "states": "('review_approved')",
            "order_by": "action_committed_at ASC", # Ensure clips.action_committed_at is used
            "id_col": "id"
        }
    }

    try:
        conn = get_db_connection(environment)
        with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
            for stage_name, config in stages_config.items():
                # Constructing the query dynamically but safely using sql.SQL and sql.Identifier
                query_str = sql.SQL("""
                    SELECT {id_col} as id, %s AS stage
                    FROM {table}
                    WHERE ingest_state IN {states}
                      AND COALESCE(retry_count, 0) < %s
                    ORDER BY {order_by}
                    LIMIT %s;
                """).format(
                    id_col=sql.Identifier(config["id_col"]),
                    table=sql.Identifier(config["table"]),
                    states=sql.SQL(config["states"]), # states string includes parentheses
                    order_by=sql.SQL(config["order_by"])
                )
                
                try:
                    cur.execute(query_str, (stage_name, max_retries, limit_per_stage))
                    items = cur.fetchall()
                    if items:
                        logger.info(f"Found {len(items)} items for stage '{stage_name}' in '{environment}' (max_retries={max_retries}).")
                        all_work_items.extend([dict(item) for item in items]) # Convert DictRow to dict
                except psycopg2.Error as e:
                    logger.error(f"DB error fetching stage '{stage_name}' in '{environment}': {e}")
                    # Optionally, re-raise or handle to continue fetching other stages
                    # For now, log and continue

    except psycopg2.Error as e:
        logger.error(f"Database connection error in get_all_pending_work for '{environment}': {e}")
        # conn will be None or the connection that failed, release_db_connection handles None
    except Exception as e:
        logger.error(f"Unexpected error in get_all_pending_work for '{environment}': {e}")
    finally:
        if conn:
            release_db_connection(conn, environment)
    
    logger.debug(f"get_all_pending_work for '{environment}' returning {len(all_work_items)} items total.")
    return all_work_items

def get_source_input_from_db(source_video_id: int, environment: str) -> str | None:
    """Fetches the original_url for a given source_video ID from the specified environment's DB."""
    task_log = get_run_logger() or log
    conn: Optional[PgConnection] = None
    input_source: Optional[str] = None
    try:
        conn = get_db_connection(environment)
        with conn:
            with conn.cursor() as cur:
                query = sql.SQL("SELECT original_url FROM source_videos WHERE id = %s")
                task_log.debug(f"Fetching original_url for source_video_id {source_video_id} (env: {environment})")
                cur.execute(query, (source_video_id,))
                result = cur.fetchone()
                if result and result[0]:
                    input_source = result[0]
                    task_log.info(f"Found original_url for source_video_id {source_video_id} (env: {environment})")
                else:
                    task_log.warning(f"No 'original_url' found for source_video_id {source_video_id} (env: {environment})")
    except (Exception, psycopg2.DatabaseError) as error:
         task_log.error(f"DB error fetching input source for ID {source_video_id} (env: {environment}): {error}", exc_info=True)
    finally:
        if conn:
            release_db_connection(conn, environment)
    return input_source

def get_pending_merge_pairs(environment: str, max_retries: int = 3) -> List[Tuple[int, int]]:
    """
    Finds pairs of clips ready for merging.
    - A 'target' clip in 'pending_merge_target' state.
    - An immediately preceding 'source' clip (by clip_identifier) from the same source_videoid
      that is in 'marked_for_merge_into_previous' state.
    - Both clips must have retry_count < max_retries.
    """
    logger = get_run_logger() or log
    merge_pairs = []
    conn = None
    query = """
        SELECT
            c_target.id AS target_clip_id,
            c_source.id AS source_clip_id
        FROM
            clips c_target
        JOIN
            clips c_source ON c_target.source_video_id = c_source.source_video_id
                        AND c_source.clip_identifier < c_target.clip_identifier -- Source must come before target
        WHERE
            c_target.ingest_state = 'pending_merge_target'
            AND COALESCE(c_target.retry_count, 0) < %s
            AND c_source.ingest_state = 'marked_for_merge_into_previous'
            AND COALESCE(c_source.retry_count, 0) < %s
            -- Ensure c_source is the DIRECTLY preceding clip intended for merge with c_target
            -- This assumes clip_identifiers are sortable and adjacent for merges.
            -- If clip_identifier structure is complex, this might need a more robust check
            -- (e.g., based on event data or a linking ID if that exists)
            AND NOT EXISTS (
                SELECT 1
                FROM clips c_intermediate
                WHERE c_intermediate.source_video_id = c_target.source_video_id
                  AND c_intermediate.clip_identifier > c_source.clip_identifier
                  AND c_intermediate.clip_identifier < c_target.clip_identifier
            )
        ORDER BY
            c_target.action_committed_at ASC, c_target.id ASC; -- Process oldest committed actions first
    """
    try:
        conn = get_db_connection(environment)
        with conn.cursor() as cur:
            cur.execute(query, (max_retries, max_retries))
            pairs = cur.fetchall()
            if pairs:
                logger.info(f"Found {len(pairs)} pending merge pairs in '{environment}' (max_retries={max_retries}).")
                merge_pairs = [(pair[0], pair[1]) for pair in pairs]
    except psycopg2.Error as e:
        logger.error(f"Database error fetching pending merge pairs for '{environment}': {e}")
    finally:
        if conn:
            release_db_connection(conn, environment)
    return merge_pairs

def get_pending_split_jobs(environment: str, max_retries: int = 3) -> List[Tuple[int, int]]:
    """
    Fetches clips that are pending a split operation.
    Returns a list of (clip_id, split_at_frame) tuples.
    Filters by retry_count.
    """
    logger = get_run_logger() or log
    split_jobs = []
    conn = None
    # Ensure processing_metadata is treated as JSONB for the ->> operator
    query = """
        SELECT
            c.id AS clip_id,
            (c.processing_metadata->>'split_at_frame')::integer AS split_at_frame
        FROM
            clips c
        WHERE
            c.ingest_state = 'pending_split'
            AND COALESCE(c.retry_count, 0) < %s
            AND c.processing_metadata IS NOT NULL
            AND c.processing_metadata->>'split_at_frame' IS NOT NULL
            -- Add a check to ensure split_at_frame is a valid integer if not done by ::integer cast
        ORDER BY
            c.action_committed_at ASC, c.id ASC; -- Process oldest committed actions first
    """
    try:
        conn = get_db_connection(environment)
        with conn.cursor() as cur:
            cur.execute(query, (max_retries,))
            jobs = cur.fetchall()
            if jobs:
                valid_jobs = []
                for job_row in jobs:
                    clip_id, split_frame = job_row[0], job_row[1]
                    if split_frame is not None: # Ensure split_frame is not NULL after cast
                        valid_jobs.append((clip_id, split_frame))
                    else:
                        logger.warning(f"Clip ID {clip_id} found in 'pending_split' but 'split_at_frame' is NULL or invalid in metadata. Skipping.")
                
                if valid_jobs:
                    logger.info(f"Found {len(valid_jobs)} pending split jobs in '{environment}' (max_retries={max_retries}).")
                    split_jobs = valid_jobs

    except psycopg2.Error as e:
        logger.error(f"Database error fetching pending split jobs for '{environment}': {e}")
        # Consider re-raising or specific error handling if this is critical
    except Exception as e_unexp:
        logger.error(f"Unexpected error fetching pending split jobs for '{environment}': {e_unexp}")
    finally:
        if conn:
            release_db_connection(conn, environment)
    return split_jobs

# ─────────────────────────────────── Immediate State Update Helpers ────────────────────────────────────
# These are used by tasks to update state *during* processing or on completion/failure.

def update_clip_state_sync(environment: str, clip_id: int, new_state: str, error_message: Optional[str] = None, expected_old_state: Optional[str] = None) -> bool:
    """Updates the ingest_state for a specific clip in the specified environment's DB."""
    processing_state = None # Define in-progress states for clips if needed for retry reset
    return _update_state_sync(
        environment=environment,
        table_name='clips',
        item_id=clip_id,
        new_state=new_state,
        error_message=error_message,
        expected_old_state=expected_old_state # Pass through
    )

def update_source_video_state_sync(
    environment: str,
    source_video_id: int,
    new_state: str,
    error_message: Optional[str] = None,
    expected_old_state: Optional[str | List[str]] = None # Allow list
) -> bool:
    """Updates the state of a source_video. Returns True if successful."""
    return _update_state_sync(
        environment=environment,
        table_name='source_videos',
        item_id=source_video_id,
        new_state=new_state,
        error_message=error_message,
        expected_old_state=expected_old_state
    )

# --- Private Helper for State Updates ---
def _update_state_sync(
    environment: str,
    table_name: str,
    item_id: int,
    new_state: str,
    error_message: Optional[str] = None,
    expected_old_state: Optional[str | List[str]] = None
) -> bool:
    """
    Internal helper to update the state of an item in a given table.
    Handles expected_old_state as a string or a list of strings.
    Returns True if the update was successful (rowcount > 0), False otherwise.
    """
    task_log = get_run_logger() or log
    conn: Optional[PgConnection] = None
    success = False

    if table_name not in ['clips', 'source_videos']:
        task_log.error(f"Invalid table name '{table_name}' for state update.")
        return False

    try:
        conn = get_db_connection(environment)
        conn.autocommit = True # Use autocommit for single updates

        with conn.cursor() as cur:
            params = []
            # Common fields for update
            query_parts = [sql.SQL("UPDATE {}").format(sql.Identifier(table_name))]
            query_parts.append(sql.SQL("SET ingest_state = %s"))
            params.append(new_state)

            if error_message:
                query_parts.append(sql.SQL(", last_error = %s"))
                params.append(error_message)
            else: # Clear error on successful state transition if no new error
                query_parts.append(sql.SQL(", last_error = NULL"))
            
            # Add retry_count increment for failure states (conceptual, adjust specific states as needed)
            # This is a placeholder, specific tasks might handle retry logic more granularly.
            # if "failed" in new_state.lower() or "error" in new_state.lower():
            # query_parts.append(sql.SQL(", retry_count = COALESCE(retry_count, 0) + 1"))
            
            # WHERE clause
            query_parts.append(sql.SQL("WHERE id = %s"))
            params.append(item_id)

            if expected_old_state:
                if isinstance(expected_old_state, list):
                    if not expected_old_state: # Empty list
                         task_log.warning(f"Empty list provided for expected_old_state for {table_name} ID {item_id}. Update will not be conditional on old state.")
                    else:
                        query_parts.append(sql.SQL("AND ingest_state = ANY(%s::text[])")) # Use = ANY for array comparison
                        params.append(expected_old_state)
                elif isinstance(expected_old_state, str):
                    query_parts.append(sql.SQL("AND ingest_state = %s"))
                    params.append(expected_old_state)
                else:
                    task_log.warning(f"Invalid type for expected_old_state: {type(expected_old_state)}. Update will not be conditional.")

            base_query_str = sql.SQL(" ").join(query_parts)
            task_log.debug(f"Executing state update: {base_query_str.as_string(conn)} with params: {params}")
            
            cur.execute(base_query_str, tuple(params))
            
            if cur.rowcount > 0:
                success = True
                task_log.info(
                    f"Item {item_id} in '{table_name}' updated to state '{new_state}'. "
                    f"Expected previous: '{expected_old_state if expected_old_state else 'any'}'. "
                    f"Rowcount: {cur.rowcount}."
                )
            else:
                # To provide better context on failure, let's see the current state
                # This query is outside the main update logic, just for logging.
                cur.execute(sql.SQL("SELECT ingest_state FROM {} WHERE id = %s").format(sql.Identifier(table_name)), (item_id,))
                current_state_on_fail_row = cur.fetchone()
                current_state_on_fail = current_state_on_fail_row[0] if current_state_on_fail_row else "NOT_FOUND"
                task_log.warning(
                    f"Failed to update item {item_id} in '{table_name}' to state '{new_state}'. Rowcount: {cur.rowcount}. "
                    f"Expected previous state: '{expected_old_state if expected_old_state else 'any'}'. Actual current state: '{current_state_on_fail}'."
                )
                
    except psycopg2.Error as db_err:
        task_log.error(f"Error updating item {item_id} in '{table_name}' state to '{new_state}': {db_err}", exc_info=True)
        success = False
    except Exception as e:
        task_log.error(f"Unexpected error during state update for {item_id} in '{table_name}': {e}", exc_info=True)
        success = False
    finally:
        if conn:
            release_db_connection(conn, environment)
    
    return success