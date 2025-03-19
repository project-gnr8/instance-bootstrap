#!/bin/bash

# Enable strict mode
set -euo pipefail

# Parse command line arguments
INST_USER=$1
STATUS_FILE=${2:-"/opt/prestage/docker-images-prestage-status.json"}
PRESTAGE_DIR=${3:-"/opt/prestage/docker-images"}

user_home=$(eval echo ~$INST_USER)
LOG_FILE=${LOG_FILE:-"$user_home/.verb-setup.log"}

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

# Check if Docker is running
check_docker() {
    echo_info "Checking if Docker is running..."
    if ! docker info &>/dev/null; then
        echo_error "Docker is not running. Please ensure Docker service is active."
        return 1
    fi
    echo_info "Docker is running correctly."
    return 0
}

# Import images from tar files
import_images() {
    echo_info "Starting Docker image import process..."
    
    # Check if status file exists
    if [ ! -f "$STATUS_FILE" ]; then
        echo_error "Status file not found: $STATUS_FILE"
        return 1
    fi
    
    # Check if prestage directory exists
    if [ ! -d "$PRESTAGE_DIR" ]; then
        echo_error "Prestage directory not found: $PRESTAGE_DIR"
        return 1
    fi
    
    # Check status
    local status=$(jq -r '.status' "$STATUS_FILE" 2>/dev/null || echo "unknown")
    if [ "$status" != "completed" ] && [ "$status" != "completed_with_errors" ]; then
        echo_error "Image prestaging not completed. Current status: $status"
        return 1
    fi
    
    # Get image list
    local images=$(jq -r '.images | .[]' "$STATUS_FILE")
    local total=$(jq -r '.total' "$STATUS_FILE")
    local completed=0
    local failed=0
    
    echo_info "Found $total images to import"
    
    # Process each image
    for image in $images; do
        # Convert image name to a valid filename
        local safe_name=$(echo "$image" | tr '/:' '_-')
        local tar_file="$PRESTAGE_DIR/${safe_name}.tar"
        
        if [ -f "$tar_file" ]; then
            echo_info "Importing image: $image from $tar_file"
            if docker load -i "$tar_file"; then
                echo_success "Successfully imported image: $image"
                ((completed++))
            else
                echo_error "Failed to import image: $image"
                ((failed++))
            fi
        else
            echo_error "Tar file not found for image: $image (expected at $tar_file)"
            ((failed++))
        fi
    done
    
    # Final status update
    if [ $failed -gt 0 ]; then
        echo_error "$failed out of $total imports failed"
        return 1
    else
        echo_success "All $total images imported successfully"
        return 0
    fi
}

# Main function
main() {
    echo_info "Starting Docker image import process"
    
    # Initialize log file
    init_log_file
    
    # Check Docker
    check_docker || exit 1
    
    # Import images
    import_images
    
    echo_info "Docker image import process completed"
}

# Execute main function
main
