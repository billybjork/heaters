import os
import psycopg2
from contextlib import contextmanager

@contextmanager
def get_db_connection(cursor_factory=None):
    db_url = os.getenv("DATABASE_URL")
    if not db_url:
        raise ValueError("DATABASE_URL environment variable not set by the Elixir caller.")
    
    conn = None
    try:
        conn = psycopg2.connect(db_url)
        if cursor_factory:
            # This context manager now supports custom cursor factories
            conn.cursor_factory = cursor_factory
        yield conn
    finally:
        if conn:
            conn.close()