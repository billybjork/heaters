"""
Filename utilities for sanitizing and validating filenames.
"""
import re


def sanitize_filename(name):
    """
    Sanitizes a string to be a valid filename and S3 key.
    
    CRITICAL: This implementation must exactly match the Elixir implementation
    in lib/heaters/utils.ex:sanitize_filename/1 to ensure consistent S3 paths
    between Python preprocessing and Elixir persistence stages.
    
    Rules (matching Elixir):
    - Only allows ASCII alphanumeric characters, hyphens, and underscores
    - Replaces all other characters (including Unicode) with underscores
    - Collapses multiple consecutive underscores into single underscore
    - Trims leading and trailing underscores
    - Returns "default" if result is empty
    
    Args:
        name: The string to sanitize
        
    Returns:
        str: A sanitized filename string
    """
    if not name:
        return "default"
    
    name = str(name)
    # Only allow ASCII alphanumeric, hyphens, and underscores (matches Elixir [^a-zA-Z0-9\-_])
    name = re.sub(r'[^a-zA-Z0-9\-_]', '_', name)
    # Collapse multiple consecutive underscores (matches Elixir _{2,})
    name = re.sub(r'_{2,}', '_', name)
    # Trim leading and trailing underscores (matches Elixir String.trim("_"))
    name = name.strip('_')
    
    # Ensure we don't return an empty string (matches Elixir fallback)
    return name if name else "default" 