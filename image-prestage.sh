#!/bin/bash

# Enable strict mode
set -euo pipefail

# Parse command line arguments
INST_USER=$1
IMAGE_LIST_JSON=$2
GCS_BUCKET=${3:-"docker-images-prestage"}

# Define constants and paths
PRESTAGE_DIR="/opt/prestage/docker-images"
STATUS_FILE="/opt/prestage/docker-images-prestage-status.json"

user_home=$(eval echo ~$INST_USER)
LOG_FILE=${LOG_FILE:-"$user_home/.verb-setup.log"}

PARALLEL_DOWNLOADS=4

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

# Install GCS client with retry logic
install_gcs_client() {
    echo_info "Installing Google Cloud SDK for GCS access..."
    
    if command -v gsutil &>/dev/null; then
        echo_info "Google Cloud SDK already installed."
        return 0
    fi
    
    # Add the Cloud SDK distribution URI as a package source
    echo_info "Adding Google Cloud SDK repository..."
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
        sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null
    
    # Import the Google Cloud public key
    echo_info "Importing Google Cloud SDK keys..."
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
        sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - > /dev/null
    
    # Update and install the Cloud SDK
    echo_info "Installing Google Cloud SDK packages..."
    sudo apt-get update -y > /dev/null
    sudo apt-get install -y google-cloud-sdk-gcs-auth-only > /dev/null
    
    echo_success "Google Cloud SDK installed successfully."
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

# Download images from GCS with parallel processing
download_images() {
    echo_info "Starting parallel image downloads from GCS bucket: $GCS_BUCKET"
    
    # Get image list from status file
    local images=$(jq -r '.images | .[]' "$STATUS_FILE")
    local total=$(jq -r '.total' "$STATUS_FILE")
    local completed=0
    local failed=0
    local image_files=()
    
    # Process each image
    for image in $images; do
        # Convert image name to a valid filename
        local safe_name=$(echo "$image" | tr '/:' '_-')
        local tar_file="$PRESTAGE_DIR/${safe_name}.tar"
        local gcs_path="gs://$GCS_BUCKET/${safe_name}.tar"
        
        image_files+=("$tar_file")
        echo_info "Queuing download for image: $image (from $gcs_path)"
    done
    
    # Use GNU Parallel to download multiple files concurrently
    if [ ${#image_files[@]} -gt 0 ]; then
        echo_info "Starting parallel downloads with $PARALLEL_DOWNLOADS concurrent jobs"
        
        # Create a temporary file with download commands
        local cmd_file=$(mktemp)
        local i=0
        
        for image in $images; do
            local safe_name=$(echo "$image" | tr '/:' '_-')
            local tar_file="$PRESTAGE_DIR/${safe_name}.tar"
            local gcs_path="gs://$GCS_BUCKET/${safe_name}.tar"
            
            echo "gsutil -o GSUtil:parallel_composite_upload_threshold=150M -m cp \"$gcs_path\" \"$tar_file\" && echo \"SUCCESS:$image\" || echo \"FAILED:$image\"" >> "$cmd_file"
            ((i++))
        done
        
        # Install GNU Parallel if not present
        if ! command -v parallel &>/dev/null; then
            echo_info "Installing GNU Parallel for concurrent downloads..."
            sudo apt-get update -y > /dev/null
            sudo apt-get install -y parallel > /dev/null
        fi
        
        # Run downloads in parallel and capture results
        parallel --jobs "$PARALLEL_DOWNLOADS" --bar < "$cmd_file" | while read -r result; do
            if [[ "$result" == SUCCESS:* ]]; then
                image="${result#SUCCESS:}"
                echo_success "Successfully downloaded image: $image"
                ((completed++))
                # Update status file with progress
                jq --arg completed "$completed" '.completed = ($completed|tonumber)' "$STATUS_FILE" | sudo tee "$STATUS_FILE.tmp" > /dev/null
                sudo mv "$STATUS_FILE.tmp" "$STATUS_FILE"
            elif [[ "$result" == FAILED:* ]]; then
                image="${result#FAILED:}"
                echo_error "Failed to download image: $image"
                ((failed++))
            fi
        done
        
        # Clean up
        rm -f "$cmd_file"
    fi
    
    # Final status update
    if [ $failed -gt 0 ]; then
        echo_error "$failed out of $total downloads failed"
        echo "{\"status\":\"completed_with_errors\",\"completed\":$completed,\"total\":$total,\"failed\":$failed,\"images\":$(jq '.images' "$STATUS_FILE")}" | sudo tee "$STATUS_FILE" > /dev/null
        return 1
    else
        echo_success "All $total images downloaded successfully"
        echo "{\"status\":\"completed\",\"completed\":$total,\"total\":$total,\"failed\":0,\"images\":$(jq '.images' "$STATUS_FILE")}" | sudo tee "$STATUS_FILE" > /dev/null
        return 0
    fi
}

# Main function
main() {
    echo_info "Starting Docker image prestaging process"
    
    # Initialize log file
    init_log_file
    
    # Install GCS client
    install_gcs_client
    
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
