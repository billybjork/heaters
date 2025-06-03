# Provides ASYNCHRONOUS database utilities using asyncpg for the APPLICATION database.

import asyncio
import json
import logging
import os
from typing import AsyncGenerator, Optional, Dict
from contextlib import asynccontextmanager
from pathlib import Path
from dotenv import load_dotenv
import sys

import asyncpg

# --- Local Imports ---
try:
    from config import get_database_url
except ImportError:
    # Fallback for local testing if config.py is not directly in sys.path
    sys_path_modified = False
    try:
        project_root_for_config = Path(__file__).resolve().parent.parent # backend/
        if str(project_root_for_config) not in sys.path:
            sys.path.insert(0, str(project_root_for_config))
            sys_path_modified = True
        from config import get_database_url
    except ImportError as e:
        print(f"ERROR importing get_database_url from config in async_db.py: {e}")
        def get_database_url(environment: str, logger=None) -> str:
            raise NotImplementedError("Dummy get_database_url in async_db.py")
    finally:
        if sys_path_modified: # Clean up sys.path if we modified it
            if sys.path[0] == str(project_root_for_config): # Basic check
                 sys.path.pop(0)


# --- Configuration ---
# Use standard logging
log = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)  # Adjust level as needed

# Define pool size constants
MIN_POOL_SIZE = int(os.getenv("MIN_ASYNC_POOL_SIZE", 1)) # TODO: Add to .env?
MAX_POOL_SIZE = int(os.getenv("MAX_ASYNC_POOL_SIZE", 10)) # TODO: Add to .env?

# --- Internal State for Environment-Specific Pools ---
_env_async_pools: Dict[str, asyncpg.Pool] = {}
_env_pool_locks: Dict[str, asyncio.Lock] = {} # One lock per environment pool


# --- Initialization for new connections ---
async def _init_connection(conn: asyncpg.Connection):
    """Initialize new connection settings, register JSON/JSONB codecs."""
    # Using id(conn) for logging can be confusing if connections are reused, but okay for init phase
    log.debug(f"Initializing new async DB connection {id(conn)}...")
    try:
        # Register JSON/JSONB <-> Python dict codecs
        for json_type in ('json', 'jsonb'):
            await conn.set_type_codec(
                json_type,
                encoder=json.dumps,
                decoder=json.loads,
                schema='pg_catalog',
                format='text' # Use text format for JSON string transfer
            )
        log.debug(f"Registered JSON/JSONB type codecs for async connection {id(conn)}.")
        # Add any other per-connection setup here if needed
        # E.g., await conn.execute("SET TIME ZONE 'UTC';")
    except Exception as e:
        log.error(f"Error setting type codecs for async connection {id(conn)}: {e}", exc_info=True)
        # Depending on severity, you might want to raise an error to prevent pool usage
        # raise


# --- Pool Management (now environment-specific) ---
async def get_db_pool(environment: str) -> asyncpg.Pool:
    """
    Creates and returns the asyncpg database connection pool for the specified environment.
    Handles potential race conditions during initial creation for each environment's pool.
    """
    task_log = logging.getLogger(f"async_db.{environment}") # Per-environment logger for pool ops

    # Get or create lock for this environment
    # This part needs to be outside the async lock if _env_pool_locks can be modified concurrently
    # by different event loop iterations for different environments initially.
    # However, typical usage pattern might be one worker = one environment.
    # For simplicity and assuming one event loop, direct access is okay here.
    if environment not in _env_pool_locks:
        _env_pool_locks[environment] = asyncio.Lock()
    
    env_specific_lock = _env_pool_locks[environment]

    # Fast path: Check if pool already exists without acquiring lock
    if environment in _env_async_pools and _env_async_pools[environment] is not None:
        return _env_async_pools[environment]

    async with env_specific_lock:
        # Check again inside the lock
        if environment in _env_async_pools and _env_async_pools[environment] is not None:
            return _env_async_pools[environment]

        task_log.info(f"Creating asyncpg pool for APPLICATION DB (Environment: {environment})...")
        
        try:
            database_url_for_env = get_database_url(environment, logger=task_log)
        except ValueError as e:
            task_log.critical(f"FATAL ERROR: Could not get DATABASE_URL for environment '{environment}'. {e}")
            raise RuntimeError(f"DATABASE_URL not configured for environment '{environment}'") from e

        log_url_display = database_url_for_env.split('@')[-1] if '@' in database_url_for_env else database_url_for_env
        task_log.info(f"Asyncpg pool for '{environment}' using DB ({log_url_display}). Min: {MIN_POOL_SIZE}, Max: {MAX_POOL_SIZE}")
        
        try:
            new_pool = await asyncpg.create_pool(
                dsn=database_url_for_env,
                min_size=MIN_POOL_SIZE,
                max_size=MAX_POOL_SIZE,
                init=_init_connection # Setup codecs for every new connection
            )
            task_log.info(f"Successfully created asyncpg pool for environment '{environment}'.")

            # Perform a quick connection test after pool creation
            async with new_pool.acquire() as connection:
                 version = await connection.fetchval("SELECT version();")
                 test_json = await connection.fetchval("SELECT '{\\\"test\\\": 1}'::jsonb;")
                 task_log.info(f"Async DB ({environment}) connection test successful. Version: {version[:15]}..., JSONB type: {type(test_json)}")
            
            _env_async_pools[environment] = new_pool
            return new_pool

        except Exception as e:
            task_log.critical(f"FATAL ERROR: Failed to create asyncpg pool for environment '{environment}': {e}", exc_info=True)
            # Ensure pool is not partially set for this environment on failure
            if environment in _env_async_pools: del _env_async_pools[environment]
            raise RuntimeError(f"Could not create asyncpg database pool for '{environment}'") from e
    
    # Should be unreachable due to logic inside lock, but as a failsafe:
    raise RuntimeError(f"Pool creation failed unexpectedly for environment '{environment}'.")


async def close_all_db_pools():
    """Closes all asyncpg database connection pools for all environments."""
    log.info("Attempting to close all asyncpg database connection pools...")
    closed_count = 0
    # Iterate over a copy of keys in case dict changes due to errors, though less likely with async
    all_environments = list(_env_async_pools.keys())

    for env_name in all_environments:
        env_specific_lock = _env_pool_locks.get(env_name)
        if not env_specific_lock:
            log.warning(f"No lock found for environment '{env_name}' during close_all_db_pools. Skipping lock acquisition.")
            # Potentially risky to proceed without lock if pool could be initializing, but close should be idempotent
        
        # Try to acquire lock, but don't wait indefinitely if something is wrong
        acquired_lock_for_close = False
        if env_specific_lock:
            try:
                await asyncio.wait_for(env_specific_lock.acquire(), timeout=5.0)
                acquired_lock_for_close = True
            except asyncio.TimeoutError:
                log.error(f"Timeout acquiring lock for environment '{env_name}' during close. Pool might be busy or deadlocked.")
            except Exception as lock_e:
                log.error(f"Error acquiring lock for environment '{env_name}' during close: {lock_e}")

        pool_to_close = _env_async_pools.get(env_name)
        if pool_to_close:
            log.info(f"Closing asyncpg pool for environment '{env_name}'...")
            try:
                await pool_to_close.close() # Gracefully close
                log.info(f"Asyncpg pool for '{env_name}' closed successfully.")
                closed_count +=1
            except Exception as e:
                log.error(f"Error closing asyncpg pool for '{env_name}': {e}", exc_info=True)
            finally:
                if env_name in _env_async_pools: del _env_async_pools[env_name]
        
        if acquired_lock_for_close and env_specific_lock:
            try: env_specific_lock.release()
            except RuntimeError: pass # Lock might not be owned if acquire failed or timed out

    log.info(f"Finished closing asyncpg pools. Closed {closed_count} pool(s) out of {len(all_environments)} tracked.")
    _env_async_pools.clear()
    _env_pool_locks.clear()


# --- Context Manager for Connections ---
@asynccontextmanager
async def get_db_connection(environment: str) -> AsyncGenerator[asyncpg.Connection, None]:
    """
    Provides an asyncpg connection from the specified environment's pool.

    Args:
        environment (str): The execution environment ("development" or "production").

    Usage:
        async with get_db_connection(environment="production") as conn:
            await conn.execute(...)
    """
    task_log = logging.getLogger(f"async_db.conn.{environment}")
    pool = await get_db_pool(environment) # Ensure pool for this environment is initialized
    connection: asyncpg.Connection | None = None
    try:
        # Acquire connection from the pool
        connection = await pool.acquire()
        task_log.debug(f"Acquired DB connection {id(connection)} from asyncpg pool '{environment}'.")
        yield connection # Provide the connection to the 'with' block
    except Exception as e:
        task_log.error(f"ERROR during asyncpg DB operation (env: {environment}): {e}", exc_info=True)
        # Re-raise the error so the calling code knows something went wrong
        raise
    finally:
        if connection:
            try:
                # Release connection back to the pool
                await pool.release(connection)
                task_log.debug(f"Released DB connection {id(connection)} back to asyncpg pool '{environment}'.")
            except Exception as release_err:
                 # Log error if releasing fails, but don't obscure the original error (if any)
                 task_log.error(f"Error releasing DB connection {id(connection)} (env: {environment}): {release_err}", exc_info=True)