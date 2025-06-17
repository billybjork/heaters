"""
Filename utilities for sanitizing and validating filenames.
"""
import re


def sanitize_filename(name):
    """
    Sanitizes a string to be a valid filename and S3 key.
    
    Removes potentially problematic characters for filenames and S3 keys,
    replaces them with underscores, and limits the length to 150 characters.
    
    Args:
        name: The string to sanitize
        
    Returns:
        str: A sanitized filename string
    """
    if not name:
        return "default_filename"
    
    name = str(name)
    # Replace non-alphanumeric characters (except dots and hyphens) with underscores
    name = re.sub(r'[^\w\.\-]+', '_', name)
    # Replace multiple consecutive underscores with single underscore
    name = re.sub(r'_+', '_', name).strip('_')
    # Limit length to 150 characters and ensure we don't return empty string
    return name[:150] if name else "default_filename" 