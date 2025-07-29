#!/usr/bin/env python3
"""
Test script to validate yt-dlp format selection strategy.

This script helps verify that our format strings are working correctly
and that we're getting access to the highest quality formats available.

Usage:
    python test_format_selection.py <youtube_url>

Example:
    python test_format_selection.py "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
"""

import sys
import yt_dlp
from pathlib import Path

def test_format_selection(url):
    """Test format selection strategy on a given URL."""
    
    print(f"Testing format selection for: {url}")
    print("=" * 60)
    
    # Test format strings from our implementation
    test_formats = [
        ("Primary (Best Quality)", "bv*+ba/b"),
        ("Fallback 1 (Compatible)", "best[ext=mp4]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best"),
        ("Fallback 2 (Whatever plays)", "worst")
    ]
    
    for name, format_str in test_formats:
        print(f"\n{name}: {format_str}")
        print("-" * 40)
        
        try:
            # Extract info without downloading
            ydl_opts = {
                'format': format_str,
                'quiet': True,
                'no_warnings': True,
                'extract_flat': False,
                'nocheckcertificate': True,
                'socket_timeout': 30
            }
            
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(url, download=False)
                
                # Get selected format
                selected_format = info.get('format_id', 'unknown')
                selected_height = info.get('height', 0)
                selected_width = info.get('width', 0)
                selected_fps = info.get('fps', 0)
                selected_vcodec = info.get('vcodec', 'unknown')
                selected_acodec = info.get('acodec', 'none')
                
                print(f"Selected format: {selected_format}")
                print(f"Resolution: {selected_width}x{selected_height}")
                print(f"FPS: {selected_fps}")
                print(f"Video codec: {selected_vcodec}")
                print(f"Audio codec: {selected_acodec}")
                
                # Check if it's a complete file or separate streams
                if selected_acodec != 'none':
                    print("Type: Complete file (video + audio)")
                else:
                    print("Type: Video-only stream (will need audio merge)")
                    
        except Exception as e:
            print(f"Error: {e}")
    
    # Also show all available formats
    print(f"\nAll Available Formats:")
    print("-" * 40)
    
    try:
        ydl_opts = {
            'quiet': True,
            'no_warnings': True,
            'extract_flat': False,
            'nocheckcertificate': True,
            'socket_timeout': 30
        }
        
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
            formats = info.get('formats', [])
            
            print(f"Total formats available: {len(formats)}")
            
            # Show top 10 video formats by resolution
            video_formats = [f for f in formats if f.get('vcodec') != 'none' and f.get('height')]
            video_formats_sorted = sorted(video_formats, key=lambda x: x.get('height', 0), reverse=True)[:10]
            
            print("\nTop 10 video formats by resolution:")
            for i, fmt in enumerate(video_formats_sorted):
                filesize_mb = fmt.get('filesize_approx', 0) // 1024 // 1024 if fmt.get('filesize_approx') else '?'
                bitrate = fmt.get('tbr', 'unknown')
                fps = fmt.get('fps', 'unknown')
                vcodec = fmt.get('vcodec', 'unknown')
                acodec = fmt.get('acodec', 'none')
                is_complete = acodec != 'none'
                complete_indicator = "🎵" if is_complete else "📹"
                print(f"  #{i+1}: {fmt.get('format_id')} - {fmt.get('height')}p@{fps}fps, {fmt.get('ext')}, {bitrate}kbps, ~{filesize_mb}MB, {vcodec}, {complete_indicator}")
                
    except Exception as e:
        print(f"Error listing formats: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python test_format_selection.py <youtube_url>")
        print("Example: python test_format_selection.py 'https://www.youtube.com/watch?v=aqz-KE-bpKQ'")
        sys.exit(1)
    
    url = sys.argv[1]
    test_format_selection(url) 