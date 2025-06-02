# Provides SYNCHRONOUS database utilities using psycopg2 (suitable for Prefect tasks)
# Connects to the APPLICATION database.

from __future__ import annotations
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
    from config import get_database_url # Import the new utility
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
logging.basicConfig(level=logging.INFO) # General logging for this module

# Load .env from project root (this helps if this module is run directly, though less common now)
# project_root_env = Path(__file__).resolve().parents[2] # Assuming heaters/src/backend/db/sync_db.py
# load_dotenv(project_root_env / ".env") # Keep this for standalone module use if any

# DATABASE_URL = os.getenv("DATABASE_URL") # This is now dynamic
# logging.getLogger().info(f"[sync_db] env DATABASE_URL = {DATABASE_URL!r}") # Old log


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
                application_name=f"prefect_worker_{environment}" # Add environment to app name
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
# IMPORTANT: These helpers now need the 'environment' parameter passed to them.

def get_all_pending_work(environment: str, limit_per_stage: int = 50) -> List[Dict[str, Any]]:
    """
    Consolidated work list for the Prefect initiator.
    Queries based on FINALIZED ingest_state (set by Commit Worker).
    Requires 'environment' to connect to the correct database.
    """
    task_log = get_run_logger() or log
    conn: Optional[PgConnection] = None
    items = []
    try:
        conn = get_db_connection(environment, cursor_factory=RealDictCursor)
        with conn:
            with conn.cursor() as cur:
                query = sql.SQL("""
                    (SELECT id, 'intake'       AS stage FROM source_videos WHERE ingest_state = %s ORDER BY id LIMIT %s)
                    UNION ALL
                    (SELECT id, 'splice'       AS stage FROM source_videos WHERE ingest_state = %s ORDER BY id LIMIT %s)
                    UNION ALL
                    (SELECT id, 'sprite'       AS stage FROM clips         WHERE ingest_state = %s ORDER BY id LIMIT %s)
                    UNION ALL
                    (SELECT id, 'post_review'  AS stage FROM clips         WHERE ingest_state = %s ORDER BY id LIMIT %s)
                    UNION ALL
                    (SELECT id, 'embedding'    AS stage FROM clips         WHERE ingest_state = %s ORDER BY id LIMIT %s)
                """)
                params = [
                    "new", limit_per_stage,
                    "downloaded", limit_per_stage,
                    "pending_sprite_generation", limit_per_stage,
                    "review_approved", limit_per_stage,
                    "keyframed", limit_per_stage,
                ]
                task_log.debug(f"Executing get_all_pending_work (env: {environment}) query with limit {limit_per_stage}")
                cur.execute(query, params)
                items = cur.fetchall()
                task_log.info(f"Found {len(items)} pending work items across stages (env: {environment}).")
    except (Exception, psycopg2.DatabaseError) as error:
        task_log.error(f"DB error fetching pending work (env: {environment}): {error}", exc_info=True)
        raise
    finally:
        if conn:
            release_db_connection(conn, environment)
    task_log.debug(f"Pending work items found (env: {environment}): {len(items)}")
    return items

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

def get_pending_merge_pairs(environment: str) -> List[Tuple[int, int]]:
    """
    Returns list of (target_id, source_id) ready for backward merge from the specified environment's DB.
    Queries based on FINALIZED ingest_state (set by Commit Worker).
    """
    task_log = get_run_logger() or log
    conn: Optional[PgConnection] = None
    pairs: List[Tuple[int, int]] = []
    try:
        conn = get_db_connection(environment, cursor_factory=RealDictCursor)
        with conn:
            with conn.cursor() as cur:
                query = sql.SQL("""
                    SELECT
                        t.id AS target_id,
                        (t.processing_metadata ->> 'merge_source_clip_id')::int AS source_id
                    FROM clips t
                    JOIN clips s ON s.id = (t.processing_metadata ->> 'merge_source_clip_id')::int
                    WHERE t.ingest_state = 'pending_merge_target'
                      AND s.ingest_state = 'marked_for_merge_into_previous';
                """)
                task_log.debug(f"Fetching pending merge pairs (env: {environment})...")
                cur.execute(query)
                pairs = [(row["target_id"], row["source_id"]) for row in cur.fetchall()]
                task_log.info(f"Found {len(pairs)} pending merge pairs (env: {environment}).")
    except (Exception, psycopg2.DatabaseError) as error:
        task_log.error(f"DB error fetching pending merge pairs (env: {environment}): {error}", exc_info=True)
    finally:
        if conn:
            release_db_connection(conn, environment)
    task_log.debug(f"Merge pairs ready (env: {environment}): {pairs}")
    return pairs

def get_pending_split_jobs(environment: str) -> List[Tuple[int, int]]:
    """
    Returns list of (clip_id, split_frame) from the specified environment's DB.
    Queries based on FINALIZED ingest_state (set by Commit Worker).
    Ensures 'split_request_at_frame' key exists in processing_metadata.
    """
    task_log = get_run_logger() or log
    conn: Optional[PgConnection] = None
    jobs: List[Tuple[int, int]] = []
    try:
        conn = get_db_connection(environment, cursor_factory=RealDictCursor)
        with conn:
            with conn.cursor() as cur:
                query = sql.SQL("""
                    SELECT id,
                           (processing_metadata ->> 'split_request_at_frame')::int AS split_frame
                    FROM clips
                    WHERE ingest_state = 'pending_split'
                      AND processing_metadata ? 'split_request_at_frame';
                """)
                task_log.debug(f"Fetching pending split jobs (env: {environment})...")
                cur.execute(query)
                fetched_rows = cur.fetchall()
                jobs = []
                for row in fetched_rows:
                    if row["id"] is not None and row["split_frame"] is not None:
                        jobs.append((row["id"], row["split_frame"]))
                    else:
                        task_log.warning(f"Skipping malformed split job data (env: {environment}): {row}")
                task_log.info(f"Found {len(jobs)} pending split jobs (env: {environment}).")
    except (Exception, psycopg2.DatabaseError) as error:
        task_log.error(f"DB error fetching pending split jobs (env: {environment}): {error}", exc_info=True)
        raise
    finally:
        if conn:
            release_db_connection(conn, environment)
    task_log.debug(f"Split jobs ready (env: {environment}): {jobs}")
    return jobs

# ─────────────────────────────────── Immediate State Update Helpers ────────────────────────────────────
# These are used by tasks to update state *during* processing or on completion/failure.
# IMPORTANT: These helpers now need the 'environment' parameter.

def _update_state_sync(
    environment: str, # Added environment parameter
    table_name: str, item_id: int, new_state: str,
    processing_state: Optional[str] = None,
    error_message: Optional[str] = None
) -> bool:
    """
    Internal helper to update ingest_state for an item in the specified environment's DB.
    Returns True if update successful (1 row affected), False otherwise.
    """
    task_log = get_run_logger() or log
    conn: Optional[PgConnection] = None
    updated = False
    try:
        conn = get_db_connection(environment) # Use environment
        with conn:
            with conn.cursor() as cur:
                set_clauses = [
                    sql.SQL("ingest_state = %s"),
                    sql.SQL("last_error = %s"),
                    sql.SQL("updated_at = NOW()")
                ]
                params: list[Any] = [new_state, error_message]

                if processing_state and new_state == processing_state:
                    set_clauses.append(sql.SQL("retry_count = 0"))
                    task_log.debug(f"Resetting retry_count for {table_name} ID {item_id} (env: {environment}) moving to state '{new_state}'.")

                if table_name == 'clips' and new_state not in ['approved_pending_deletion', 'archived_pending_deletion']:
                    set_clauses.append(sql.SQL("action_committed_at = NULL"))

                query = sql.SQL("UPDATE {} SET {} WHERE id = %s").format(
                    sql.Identifier(table_name),
                    sql.SQL(", ").join(set_clauses)
                )
                params.append(item_id)

                task_log.debug(f"Updating {table_name} ID {item_id} to state '{new_state}' (env: {environment}) (Error: {bool(error_message)})")
                cur.execute(query, params)

                if cur.rowcount == 1:
                    task_log.info(f"Successfully updated {table_name} ID {item_id} to state '{new_state}' (env: {environment}).")
                    updated = True
                elif cur.rowcount == 0:
                    task_log.warning(f"Update state for {table_name} ID {item_id} to '{new_state}' (env: {environment}) affected 0 rows.")
                else:
                    task_log.error(f"Update state for {table_name} ID {item_id} to '{new_state}' (env: {environment}) affected {cur.rowcount} rows! Investigate.")
                    updated = False
    except (Exception, psycopg2.DatabaseError) as error:
        task_log.error(f"DB error updating state for {table_name} ID {item_id} to '{new_state}' (env: {environment}): {error}", exc_info=True)
        updated = False
    finally:
        if conn:
            release_db_connection(conn, environment) # Pass environment
    return updated

def update_clip_state_sync(environment: str, clip_id: int, new_state: str, error_message: Optional[str] = None) -> bool:
    """Updates the ingest_state for a specific clip in the specified environment's DB."""
    processing_state = None # Define in-progress states for clips if needed for retry reset
    return _update_state_sync(environment, "clips", clip_id, new_state, processing_state, error_message)

def update_source_video_state_sync(environment: str, source_video_id: int, new_state: str, error_message: Optional[str] = None) -> bool:
    """Updates the ingest_state for a specific source_video in the specified environment's DB."""
    processing_state = "downloading" # Example for retry reset on starting 'downloading'
    return _update_state_sync(environment, "source_videos", source_video_id, new_state, processing_state, error_message)

# Prefect can call these via deployment configuration or directly in flow definitions if needed.