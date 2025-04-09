import os
import random
import asyncpg # Asynchronous PostgreSQL driver
from fastapi import FastAPI, Request, HTTPException, Query, Depends
from fastapi.responses import RedirectResponse, FileResponse, HTMLResponse
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
from dotenv import load_dotenv
import numpy as np # Still needed for embedding list conversion for pgvector

# --- Environment Loading ---
load_dotenv() # Load variables from .env file in the project root

# --- Configuration ---
DATABASE_URL = os.getenv("DATABASE_URL")
MEDIA_BASE_DIR = os.getenv("MEDIA_BASE_DIR")
DEFAULT_MODEL_NAME = os.getenv("DEFAULT_MODEL_NAME", "openai/clip-vit-base-patch32") # Set default model
DEFAULT_GENERATION_STRATEGY = os.getenv("DEFAULT_GENERATION_STRATEGY", "keyframe_midpoint") # Set default strategy
NUM_RESULTS = int(os.getenv("NUM_RESULTS", 10)) # Number of similar clips to show

# --- Input Validation ---
if not DATABASE_URL:
    raise ValueError("DATABASE_URL not found in environment variables. Check your .env file.")
if not MEDIA_BASE_DIR:
    raise ValueError("MEDIA_BASE_DIR not found in environment variables. Check your .env file.")
if not os.path.isdir(MEDIA_BASE_DIR):
    raise ValueError(f"MEDIA_BASE_DIR '{MEDIA_BASE_DIR}' does not exist or is not a directory.")

print(f"Using Database URL (partially hidden): {DATABASE_URL[:15]}...")
print(f"Using Media Base Directory: {MEDIA_BASE_DIR}")
print(f"Default Model: {DEFAULT_MODEL_NAME}")
print(f"Default Strategy: {DEFAULT_GENERATION_STRATEGY}")

# --- Database Connection Pool ---
db_pool = None

async def get_db_connection():
    """FastAPI dependency to get a connection from the pool."""
    if db_pool is None:
         raise RuntimeError("Database connection pool is not initialized.")
    async with db_pool.acquire() as connection:
        yield connection

# --- FastAPI App Setup ---
app = FastAPI(title="Snowboard Similarity Search")

@app.on_event("startup")
async def startup_db_client():
    """Create database connection pool on startup."""
    global db_pool
    try:
        db_pool = await asyncpg.create_pool(DATABASE_URL)
        # Try a simple query to confirm connection
        async with db_pool.acquire() as connection:
             version = await connection.fetchval("SELECT version();")
             print(f"Database connection pool created successfully. PostgreSQL version: {version[:15]}...")
    except Exception as e:
        print(f"FATAL: Could not create database connection pool: {e}")
        # Optionally exit or prevent app startup
        raise RuntimeError(f"Database connection failed: {e}")


@app.on_event("shutdown")
async def shutdown_db_client():
    """Close database connection pool on shutdown."""
    if db_pool:
        await db_pool.close()
        print("Database connection pool closed.")

# --- Static Files and Templates ---
# Make sure 'static' and 'templates' directories exist at the project root
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")

# --- Helper Functions ---
def format_clip_data(record, request: Request):
    """Formats a database record into a dictionary for the template."""
    if not record:
        return None
    # Use clip_identifier for display title if needed, or add a title column later
    title = record['clip_identifier'].replace("_", " ").replace("-", " ").title()
    return {
        "clip_id": record['clip_identifier'],
        "title": title,
        "keyframe_url": request.url_for('serve_media', filepath=record['keyframe_filepath']) if record['keyframe_filepath'] else None,
        "video_url": request.url_for('serve_media', filepath=record['clip_filepath']) if record['clip_filepath'] else None,
        # Add score later if needed for results
    }

# --- FastAPI Routes ---

@app.get("/", response_class=HTMLResponse, name="index")
async def index(request: Request, conn: asyncpg.Connection = Depends(get_db_connection)):
    """Redirects to a random clip's query page."""
    try:
        # Fetch a random clip identifier from the DB
        random_clip_record = await conn.fetchrow(
            "SELECT clip_identifier FROM clips ORDER BY RANDOM() LIMIT 1"
        )
        if random_clip_record:
            random_clip_id = random_clip_record['clip_identifier']
            # Include default model/strategy in the redirect URL query params
            redirect_url = request.url_for('query_clip', clip_id=random_clip_id).include_query_params(
                 model_name=DEFAULT_MODEL_NAME,
                 strategy=DEFAULT_GENERATION_STRATEGY
            )
            return RedirectResponse(url=redirect_url)
        else:
            # Handle case where there are no clips in the DB yet
             return templates.TemplateResponse("index.html", {"request": request, "query": None, "results": [], "error": "No clips found in the database."})

    except Exception as e:
        print(f"Error fetching random clip: {e}")
        raise HTTPException(status_code=500, detail="Error retrieving data from database.")


@app.get("/query/{clip_id}", response_class=HTMLResponse, name="query_clip")
async def query_clip(
    clip_id: str,
    request: Request,
    conn: asyncpg.Connection = Depends(get_db_connection),
    # Add query parameters for model and strategy selection
    model_name: str = Query(DEFAULT_MODEL_NAME, alias="model"),
    strategy: str = Query(DEFAULT_GENERATION_STRATEGY, alias="strategy")
):
    """Displays a query clip and finds similar clips based on embeddings."""
    print(f"Querying for clip_id='{clip_id}', model='{model_name}', strategy='{strategy}'")
    query_info = None
    results = []
    error_message = None

    try:
        # 1. Fetch Query Clip Info (including its embedding ID if needed, and file paths)
        query_clip_record = await conn.fetchrow(
            """
            SELECT c.id, c.clip_identifier, c.clip_filepath, c.keyframe_filepath, e.embedding
            FROM clips c
            LEFT JOIN embeddings e ON c.id = e.clip_id
                                  AND e.model_name = $2
                                  AND e.generation_strategy = $3
            WHERE c.clip_identifier = $1;
            """,
            clip_id, model_name, strategy
        )

        if not query_clip_record:
            # If clip_id doesn't exist at all
            print(f"Clip identifier '{clip_id}' not found in database.")
            # Maybe redirect to index or show error? Let's try redirecting to random
            try:
                random_clip_record = await conn.fetchrow("SELECT clip_identifier FROM clips ORDER BY RANDOM() LIMIT 1")
                if random_clip_record:
                    random_clip_id = random_clip_record['clip_identifier']
                    redirect_url = request.url_for('query_clip', clip_id=random_clip_id).include_query_params(model=model_name, strategy=strategy)
                    return RedirectResponse(url=redirect_url)
                else:
                    raise HTTPException(status_code=404, detail="Requested clip not found, and no other clips available.")
            except Exception as rand_e:
                 raise HTTPException(status_code=500, detail=f"Requested clip not found, error finding alternative: {rand_e}")


        query_info = format_clip_data(query_clip_record, request)
        query_embedding_bytes = query_clip_record['embedding'] # This is bytea from DB

        if not query_info or query_info.get("video_url") is None:
             print(f"Warning: Missing file path data for query clip {clip_id}.")
             # Handle case where clip exists but paths are missing
             error_message = f"Missing file path information for clip '{clip_id}'."
             # Allow showing the clip info we have, but no similarity search

        if not query_embedding_bytes:
             print(f"Warning: Embedding not found for query clip {clip_id} with model='{model_name}', strategy='{strategy}'. Cannot perform similarity search.")
             error_message = f"Embedding not found for clip '{clip_id}' (Model: {model_name}, Strategy: {strategy}). Cannot find similar clips."
             # Render template without results
             return templates.TemplateResponse("index.html", {"request": request, "query": query_info, "results": [], "error": error_message, "model_name": model_name, "strategy": strategy})


        # Convert bytea embedding to numpy array list for pgvector query
        # Assuming the bytea stores raw float32 bytes
        query_embedding_vector = np.frombuffer(query_embedding_bytes, dtype=np.float32).tolist()


        # 2. Find Similar Clips using pgvector
        # Use <=> for cosine distance (lower is better, 0=identical, 2=opposite)
        # Calculate similarity score as 1 - (distance / 2) or just 1 - distance if normalized
        # We use 1 - distance assuming vectors are normalized (like CLIP)
        similarity_query = """
            SELECT
                c.clip_identifier,
                c.clip_filepath,
                c.keyframe_filepath,
                1 - (e.embedding <=> $1::vector) AS similarity_score -- Calculate cosine similarity
            FROM embeddings e
            JOIN clips c ON e.clip_id = c.id
            WHERE e.model_name = $2
              AND e.generation_strategy = $3
              AND c.clip_identifier != $4 -- Exclude the query clip itself
            ORDER BY e.embedding <=> $1::vector -- Order by cosine distance ASC (most similar first)
            LIMIT $5;
        """
        similar_records = await conn.fetch(
            similarity_query,
            query_embedding_vector, # Pass the list representation
            model_name,
            strategy,
            clip_id, # Query clip identifier to exclude
            NUM_RESULTS
        )

        # 3. Format Results
        for record in similar_records:
            formatted = format_clip_data(record, request)
            if formatted:
                formatted["score"] = record['similarity_score']
                results.append(formatted)

    except asyncpg.exceptions.UndefinedFunctionError as e:
         print(f"DATABASE ERROR: pgvector function error. Is the pgvector extension installed and enabled? Error: {e}")
         raise HTTPException(status_code=500, detail="Database error: Vector operations not available.")
    except Exception as e:
        print(f"Error during query for clip {clip_id}: {e}")
        # Don't crash, try to return template with error
        error_message = f"An unexpected error occurred: {e}"


    # Render the template
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "query": query_info,
            "results": results,
            "error": error_message,
            "model_name": model_name, # Pass these back for display or forms
            "strategy": strategy
        }
    )


@app.get("/media/{filepath:path}", name="serve_media")
async def serve_media(filepath: str):
    """Serves media files (videos, images) safely from the MEDIA_BASE_DIR."""
    # Use the configured MEDIA_BASE_DIR
    safe_base_path = os.path.abspath(MEDIA_BASE_DIR)
    # Construct the full path requested
    requested_path = os.path.abspath(os.path.join(safe_base_path, filepath))

    # --- Security Check: Ensure path is within MEDIA_BASE_DIR ---
    # Use os.path.commonpath (Python 3.5+) or check prefix after resolving paths
    if os.path.commonpath([safe_base_path]) != os.path.commonpath([safe_base_path, requested_path]):
        print(f"Warning: Attempted directory traversal: {filepath}")
        raise HTTPException(status_code=404, detail="File not found (Invalid Path)")

    if not os.path.isfile(requested_path):
        print(f"Warning: Media file not found at: {requested_path}")
        raise HTTPException(status_code=404, detail="File not found")

    print(f"Serving media file: {requested_path}")
    return FileResponse(requested_path)

# --- Main Execution ---
if __name__ == '__main__':
    import uvicorn
    print("Starting FastAPI server...")
    # No longer loading embeddings from file at startup
    uvicorn.run("app:app", host="127.0.0.1", port=5001, reload=True)