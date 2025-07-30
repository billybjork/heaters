#!/bin/bash

# Fix proxy files by moving MOOV atom to the front for fast seeking
# This script processes all proxy files in the S3 bucket to optimize them for streaming

set -e

# Configuration
BUCKET_NAME="${S3_DEV_BUCKET_NAME:-heaters-dev}"
REGION="${AWS_REGION:-us-west-1}"
PROXY_PREFIX="proxies/"

echo "Starting proxy file optimization..."
echo "Bucket: $BUCKET_NAME"
echo "Region: $REGION"

# List all proxy files
echo "Listing proxy files..."
aws s3 ls "s3://$BUCKET_NAME/$PROXY_PREFIX" --recursive --region "$REGION" | grep "\.mp4$" | while read -r line; do
    # Extract file path from AWS CLI output
    file_path=$(echo "$line" | awk '{print $4}')
    filename=$(basename "$file_path")
    
    echo "Processing: $filename"
    
    # Download the file
    echo "  Downloading..."
    aws s3 cp "s3://$BUCKET_NAME/$file_path" "/tmp/$filename" --region "$REGION"
    
    # Check if file needs fixing (test if moov is at the end)
    if ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "/tmp/$filename" > /dev/null 2>&1; then
        echo "  File is valid, checking if optimization needed..."
        
        # Create optimized version
        echo "  Creating optimized version..."
        ffmpeg -i "/tmp/$filename" -c copy -movflags +faststart "/tmp/${filename%.*}_optimized.mp4" -y
        
        # Verify the optimized file works
        if ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "/tmp/${filename%.*}_optimized.mp4" > /dev/null 2>&1; then
            echo "  Uploading optimized version..."
            aws s3 cp "/tmp/${filename%.*}_optimized.mp4" "s3://$BUCKET_NAME/$file_path" --region "$REGION"
            echo "  ✓ Optimized: $filename"
        else
            echo "  ✗ Failed to optimize: $filename"
        fi
        
        # Clean up
        rm -f "/tmp/$filename" "/tmp/${filename%.*}_optimized.mp4"
    else
        echo "  ✗ Invalid file: $filename"
        rm -f "/tmp/$filename"
    fi
done

echo "Proxy file optimization complete!" 