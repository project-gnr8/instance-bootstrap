#!/bin/bash

# Enable strict mode
set -euo pipefail

# Parse command line arguments
INST_USER=$1
IMAGE_LIST_JSON=$2
GCS_BUCKET=${3:-"brev-image-prestage"}

# Define constants and paths
PRESTAGE_DIR="/opt/prestage/docker-images"
STATUS_FILE="/opt/prestage/docker-images-prestage-status.json"
SIGNED_URL_SERVICE="https://gcs-signed-url-service-145097832422.us-central1.run.app"

user_home=$(eval echo ~$INST_USER)
LOG_FILE=${LOG_FILE:-"$user_home/.verb-setup.log"}

# Configure parallel downloads
# Use more threads for faster downloads
PARALLEL_CONNECTIONS=16
# Use more processes for parallel downloads
PARALLEL_DOWNLOADS=8
# Set higher sliced download threshold for large files (50MB)
MIN_SPLIT_SIZE="50M"

# Initialize log file
init_log_file() {
    local log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        sudo mkdir -p "$log_dir" 2>/dev/null
        sudo chmod 775 "$log_dir"
    fi
    
    sudo touch "$LOG_FILE" 2>/dev/null
    sudo chmod 644 "$LOG_FILE"
    sudo chown "$INST_USER":"$INST_USER" "$LOG_FILE"
    echo "[$( date +"%Y-%m-%dT%H:%M:%S%z" )] [INFO] Log initialized at $LOG_FILE" >> "$LOG_FILE"
}

# Enhanced logging function with ISO 8601 timestamps
echo_info() {
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    # Format for console with colors
    printf "\033[1;34m[INFO]\033[0m [%s] %s\n" "$timestamp" "$1" >&1
    # Format for log file (without colors)
    printf "[%s] [INFO] %s\n" "$timestamp" "$1" >> "$LOG_FILE"
}

echo_error() {
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    # Format for console with colors
    printf "\033[1;31m[ERROR]\033[0m [%s] %s\n" "$timestamp" "$1" >&1
    # Format for log file (without colors)
    printf "[%s] [ERROR] %s\n" "$timestamp" "$1" >> "$LOG_FILE"
}

echo_success() {
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    # Format for console with colors
    printf "\033[1;32m[SUCCESS]\033[0m [%s] %s\n" "$timestamp" "$1" >&1
    # Format for log file (without colors)
    printf "[%s] [SUCCESS] %s\n" "$timestamp" "$1" >> "$LOG_FILE"
}

# Prepare the staging directory
prepare_staging_dir() {
    echo_info "Preparing image staging directory: $PRESTAGE_DIR"
    
    # Create parent directory if it doesn't exist
    local parent_dir=$(dirname "$PRESTAGE_DIR")
    if [ ! -d "$parent_dir" ]; then
        sudo mkdir -p "$parent_dir"
        sudo chmod 775 "$parent_dir"
        sudo chown "$INST_USER":"$INST_USER" "$parent_dir"
    fi
    
    # Create image directory if it doesn't exist
    if [ ! -d "$PRESTAGE_DIR" ]; then
        sudo mkdir -p "$PRESTAGE_DIR"
        sudo chmod 775 "$PRESTAGE_DIR"
        sudo chown "$INST_USER":"$INST_USER" "$PRESTAGE_DIR"
    fi
    
    # Create status file directory if it doesn't exist
    local status_dir=$(dirname "$STATUS_FILE")
    if [ ! -d "$status_dir" ]; then
        sudo mkdir -p "$status_dir"
        sudo chmod 775 "$status_dir"
        sudo chown "$INST_USER":"$INST_USER" "$status_dir"
    fi
    
    # Initialize status file
    echo '{"status":"initializing","completed":0,"total":0,"images":[]}' | sudo tee "$STATUS_FILE" > /dev/null
    sudo chmod 644 "$STATUS_FILE"
    sudo chown "$INST_USER":"$INST_USER" "$STATUS_FILE"
}

# Parse image list and prepare for download
parse_image_list() {
    echo_info "Parsing image list..."
    
    # Default image if none provided
    if [ -z "$IMAGE_LIST_JSON" ]; then
        IMAGE_LIST_JSON='["nvcr.io/nvidia/rapidsai/notebooks:24.12-cuda12.5-py3.12"]'
    fi
    
    # Count total images
    local total_images=$(echo "$IMAGE_LIST_JSON" | jq '. | length')
    echo_info "Found $total_images images to process"
    
    # Update status file
    echo "{\"status\":\"downloading\",\"completed\":0,\"total\":$total_images,\"images\":$IMAGE_LIST_JSON}" | sudo tee "$STATUS_FILE" > /dev/null
}

# Update status file
update_status() {
    local status=$1
    local completed=$2
    local total=$3
    echo "{\"status\":\"$status\",\"completed\":$completed,\"total\":$total,\"images\":$(jq '.images' "$STATUS_FILE")}" | sudo tee "$STATUS_FILE" > /dev/null
}

# Get signed URL from GCS signed URL service
get_signed_url() {
    local object_name=$1
    local expiration=${2:-3600}
    
    echo_info "Requesting signed URL for object: $object_name"
    
    # Prepare request payload
    local payload="{\"object\":\"$object_name\",\"expiration\":$expiration,\"method\":\"GET\"}"
    
    # Make request to signed URL service
    local response
    response=$(curl -s -X POST "$SIGNED_URL_SERVICE/generate-signed-url" \
                   -H "Content-Type: application/json" \
                   -d "$payload")
    
    # Check if request was successful
    if [ $? -ne 0 ]; then
        echo_error "Failed to get signed URL for object: $object_name"
        return 1
    fi
    
    # Extract signed URL from response
    local signed_url=$(echo "$response" | jq -r '.signed_url')
    
    if [ -z "$signed_url" ] || [ "$signed_url" = "null" ]; then
        echo_error "Invalid response from signed URL service: $response"
        return 1
    fi
    
    echo "$signed_url"
    return 0
}

# Download images using aria2c with parallel processing
download_images() {
    echo_info "Starting Docker image downloads using signed URLs"
    
    # Parse image list from JSON
    local images=$(echo "$IMAGE_LIST_JSON" | jq -r '.[]')
    local total=$(echo "$IMAGE_LIST_JSON" | jq -r '. | length')
    local completed=0
    local failed=0
    
    # Update status file with total count
    update_status "downloading" $completed $total
    
    # Process each image
    for image in $images; do
        # Convert image name to a valid filename
        local safe_name=$(echo "$image" | tr '/:' '_-')
        local tar_file="$PRESTAGE_DIR/${safe_name}.tar"
        
        echo_info "Processing image: $image"
        
        # Add image to status file
        jq --arg img "$image" '.images += [$img]' "$STATUS_FILE" | sudo tee "$STATUS_FILE.tmp" > /dev/null
        sudo mv "$STATUS_FILE.tmp" "$STATUS_FILE"
        
        # Get signed URL for the object
        local signed_url
        signed_url=$(get_signed_url "${safe_name}.tar")
        
        if [ $? -ne 0 ]; then
            echo_error "Failed to get signed URL for image: $image"
            ((failed++))
            continue
        fi
        
        echo_info "Downloading image: $image using aria2c"
        
        # Download the image using aria2c with parallel connections
        if aria2c --file-allocation=none \
                  --max-connection-per-server=$PARALLEL_CONNECTIONS \
                  --max-concurrent-downloads=$PARALLEL_DOWNLOADS \
                  --min-split-size=$MIN_SPLIT_SIZE \
                  --dir="$(dirname "$tar_file")" \
                  --out="$(basename "$tar_file")" \
                  "$signed_url"; then
            echo_success "Successfully downloaded image: $image"
            ((completed++))
        else
            echo_error "Failed to download image: $image"
            ((failed++))
        fi
        
        # Update status file
        update_status "downloading" $completed $total
    done
    
    # Final status update
    if [ $failed -gt 0 ]; then
        update_status "completed_with_errors" $completed $total
        echo_error "$failed out of $total downloads failed"
        return 1
    else
        update_status "completed" $completed $total
        echo_success "All $total images downloaded successfully"
        return 0
    fi
}

# Main function
main() {
    echo_info "Starting Docker image prestaging process"
    
    # Initialize log file
    init_log_file
    
    # Check for required tools
    for cmd in curl jq aria2c; do
        if ! command -v $cmd &>/dev/null; then
            echo_error "Required tool '$cmd' is not installed. Please run oneshot.sh first."
            exit 1
        fi
    done
    
    # Prepare staging directory
    prepare_staging_dir
    
    # Parse image list
    parse_image_list
    
    # Download images
    download_images
    
    echo_info "Docker image prestaging process completed"
}

# Execute main function
main
