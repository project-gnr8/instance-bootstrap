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

# Image name to GCS object mapping
# This maps Docker image names to their corresponding GCS object names
declare -A IMAGE_TO_OBJECT_MAP
IMAGE_TO_OBJECT_MAP["nvcr.io/nvidia/rapidsai/notebooks:24.12-cuda12.5-py3.12"]="rapidsai-notebooks-24-12.tar"
IMAGE_TO_OBJECT_MAP["nvcr.io/nvidia/clara/clara-parabricks:4.4.0-1"]="clara-parabricks-4-4-0.tar"
IMAGE_TO_OBJECT_MAP["nvcr.io/nvidia/nemo:24.12"]="nvidia-nemo-24-12.tar"
IMAGE_TO_OBJECT_MAP["egalinkin/demo"]="egalinkin-demo.tar"

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

echo_timing() {
    local operation=$1
    local duration=$2
    local size=${3:-"unknown"}
    local rate=${4:-"unknown"}
    
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    # Format for console with colors
    printf "\033[1;36m[TIMING]\033[0m [%s] Operation: %s, Duration: %.2f seconds, Size: %s, Rate: %s\n" \
        "$timestamp" "$operation" "$duration" "$size" "$rate" >&1
    # Format for log file (without colors)
    printf "[%s] [TIMING] Operation: %s, Duration: %.2f seconds, Size: %s, Rate: %s\n" \
        "$timestamp" "$operation" "$duration" "$size" "$rate" >> "$LOG_FILE"
}

get_file_size() {
    local file=$1
    if [ -f "$file" ]; then
        du -h "$file" | cut -f1
    else
        echo "unknown"
    fi
}

calculate_rate() {
    local file_size=$1  # in bytes
    local duration=$2   # in seconds
    
    if [ "$file_size" = "unknown" ] || [ "$duration" = "0" ]; then
        echo "unknown"
        return
    fi
    
    # Calculate rate in MB/s
    local rate=$(echo "scale=2; $file_size / 1024 / 1024 / $duration" | bc)
    echo "${rate} MB/s"
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
    update_status "downloading" 0 $total_images
}

# Update status file
update_status() {
    local status=$1
    local completed=$2
    local total=$3
    
    # Use jq to properly update the status file with valid JSON
    if ! jq -n \
        --arg status "$status" \
        --argjson completed "$completed" \
        --argjson total "$total" \
        --argjson images "$(jq '.images' "$STATUS_FILE" 2>/dev/null || echo '[]')" \
        '{status: $status, completed: $completed, total: $total, images: $images}' > "$STATUS_FILE.tmp"; then
        echo_error "Failed to update status file" >&2
        return 1
    fi
    
    sudo mv "$STATUS_FILE.tmp" "$STATUS_FILE"
    return 0
}

# URL decode function to handle encoded URLs
url_decode() {
    local url="$1"
    # Replace %2F with / and other common URL encodings
    url="${url//"%2F"/"/"}"
    url="${url//"%3A"/":"}"
    url="${url//"%3F"/"?"}"
    url="${url//"%3D"/"="}"
    url="${url//"%26"/"&"}"
    echo "$url"
}

# Get signed URL from GCS signed URL service
get_signed_url() {
    local object_name=$1
    local expiration=${2:-3600}
    
    echo_info "Requesting signed URL for object: $object_name"
    
    # Prepare request payload
    local payload="{\"object\":\"$object_name\",\"expiration\":$expiration,\"method\":\"GET\"}"
    echo_info "Request payload: $payload"
    
    # Create temp files for response headers and body
    local headers_file=$(mktemp)
    local response_file=$(mktemp)
    
    echo_info "Making request to signed URL service: $SIGNED_URL_SERVICE/generate-signed-url"
    
    # Make request to signed URL service with verbose output
    local curl_exit_code
    curl -v -s -X POST "$SIGNED_URL_SERVICE/generate-signed-url" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -D "$headers_file" \
        -o "$response_file"
    curl_exit_code=$?
    
    # Log headers and response
    echo_info "HTTP Response Headers:"
    cat "$headers_file" | while read line; do echo_info "  $line"; done
    
    echo_info "HTTP Response Body:"
    cat "$response_file" | while read line; do echo_info "  $line"; done
    
    # Check if request was successful
    if [ $curl_exit_code -ne 0 ]; then
        echo_error "curl failed with exit code: $curl_exit_code"
        rm -f "$headers_file" "$response_file"
        return 1
    fi
    
    # Extract signed URL from response
    local response=$(cat "$response_file")
    local signed_url=$(echo "$response" | jq -r '.signed_url')
    
    if [ -z "$signed_url" ] || [ "$signed_url" = "null" ]; then
        echo_error "Invalid response from signed URL service: $response"
        rm -f "$headers_file" "$response_file"
        return 1
    fi
    
    # Clean the URL - remove any newlines, carriage returns, or extra spaces
    signed_url="${signed_url//[$'\n\r ']}"
    
    # Decode the URL to ensure it's properly formatted
    local decoded_url=$(url_decode "$signed_url")
    
    echo_info "Original signed URL: $signed_url"
    echo_info "Decoded signed URL: $decoded_url"
    
    # Clean up temp files
    rm -f "$headers_file" "$response_file"
    
    echo "$decoded_url"
    return 0
}

# Get object name for an image using the mapping
get_object_name() {
    local image=$1
    local object_name=""
    
    # Check if image exists in the mapping
    if [[ -n "${IMAGE_TO_OBJECT_MAP[$image]:-}" ]]; then
        object_name="${IMAGE_TO_OBJECT_MAP[$image]}"
        echo_info "Using mapped object name for $image: $object_name" >&2
    else
        # Fallback to the default naming convention if not in the mapping
        object_name=$(echo "$image" | tr '/:' '_-').tar
        echo_info "No mapping found for $image, using default name: $object_name" >&2
    fi
    
    echo "$object_name"
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
    
    # Create a summary file for timing data
    local summary_file="$PRESTAGE_DIR/download_timing_summary.json"
    echo '{"images":[]}' > "$summary_file"
    sudo chmod 644 "$summary_file"
    sudo chown "$INST_USER":"$INST_USER" "$summary_file"
    
    # Process each image
    for image in $images; do
        # Get the appropriate object name from the mapping
        local object_name=$(get_object_name "$image")
        
        # Use the same safe_name for the local file
        local safe_name=$(echo "$image" | tr '/:' '_-')
        local tar_file="$PRESTAGE_DIR/${safe_name}.tar"
        
        echo_info "Processing image: $image (object: $object_name)"
        
        # Add image to status file - ensure proper JSON formatting
        if ! jq --arg img "$image" '.images += [$img]' "$STATUS_FILE" > "$STATUS_FILE.tmp"; then
            echo_error "Failed to update status file with image: $image"
            ((failed++))
            continue
        fi
        sudo mv "$STATUS_FILE.tmp" "$STATUS_FILE"
        
        # Get signed URL for the object
        local signed_url
        signed_url=$(get_signed_url "$object_name")
        
        if [ $? -ne 0 ]; then
            echo_error "Failed to get signed URL for image: $image (object: $object_name)"
            ((failed++))
            continue
        fi
        
        echo_info "Downloading image: $image using aria2c"
        
        # Test URL with curl first to check for errors
        echo_info "Testing URL with curl -I to check for errors:"
        curl -I "$signed_url" 2>&1 | while read line; do echo_info "  $line"; done
        
        # Record start time
        local start_time=$(date +%s.%N)
        
        # Try using different download methods
        local download_success=false
        local download_method="unknown"
        
        # First attempt: Try aria2c with direct URL (decoded)
        echo_info "Attempting download with aria2c..."
        if aria2c --file-allocation=none \
                  --max-connection-per-server=$PARALLEL_CONNECTIONS \
                  --max-concurrent-downloads=$PARALLEL_DOWNLOADS \
                  --min-split-size=$MIN_SPLIT_SIZE \
                  --dir="$(dirname "$tar_file")" \
                  --out="$(basename "$tar_file")" \
                  --allow-overwrite=true \
                  --console-log-level=debug \
                  "$signed_url" 2>&1 | while read line; do echo_info "  aria2c: $line"; done; then
            download_success=true
            download_method="aria2c_direct"
            echo_info "Successfully downloaded with aria2c direct URL"
        else
            echo_info "aria2c direct URL failed, trying with curl as fallback..."
            
            # Second attempt: Try curl as fallback with verbose output
            if curl -v -L -o "$tar_file" "$signed_url" 2>&1 | while read line; do echo_info "  curl: $line"; done; then
                download_success=true
                download_method="curl"
                echo_info "Successfully downloaded with curl fallback"
            else
                echo_info "curl failed, trying with wget as final fallback..."
                
                # Third attempt: Try wget as final fallback with verbose output
                if wget -v --no-check-certificate -O "$tar_file" "$signed_url" 2>&1 | while read line; do echo_info "  wget: $line"; done; then
                    download_success=true
                    download_method="wget"
                    echo_info "Successfully downloaded with wget fallback"
                fi
            fi
        fi
        
        # Record end time and calculate duration
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc)
        
        if [ "$download_success" = true ]; then
            # Get file size in bytes for rate calculation
            local file_size_bytes=$(stat -c%s "$tar_file" 2>/dev/null || echo "unknown")
            local file_size_human=$(get_file_size "$tar_file")
            local transfer_rate=$(calculate_rate "$file_size_bytes" "$duration")
            
            # Log timing information
            echo_timing "download_${download_method}_$image" "$duration" "$file_size_human" "$transfer_rate"
            
            # Add to summary JSON
            jq --arg img "$image" \
               --arg obj "$object_name" \
               --arg method "$download_method" \
               --arg duration "$duration" \
               --arg size "$file_size_human" \
               --arg rate "$transfer_rate" \
               --argjson connections "$PARALLEL_CONNECTIONS" \
               --argjson concurrent "$PARALLEL_DOWNLOADS" \
               '.images += [{"image": $img, "object": $obj, "operation": "download", "method": $method, "duration": $duration, "size": $size, "rate": $rate, "connections": $connections, "concurrent_downloads": $concurrent}]' \
               "$summary_file" > "$summary_file.tmp" && sudo mv "$summary_file.tmp" "$summary_file"
            
            echo_success "Successfully downloaded image: $image using $download_method"
            ((completed++))
        else
            # Log timing information for failed download
            echo_timing "download_failed_$image" "$duration" "unknown" "unknown"
            
            # Add to summary JSON
            jq --arg img "$image" \
               --arg obj "$object_name" \
               --arg duration "$duration" \
               --argjson connections "$PARALLEL_CONNECTIONS" \
               --argjson concurrent "$PARALLEL_DOWNLOADS" \
               '.images += [{"image": $img, "object": $obj, "operation": "download_failed", "duration": $duration, "size": "unknown", "rate": "unknown", "connections": $connections, "concurrent_downloads": $concurrent}]' \
               "$summary_file" > "$summary_file.tmp" && sudo mv "$summary_file.tmp" "$summary_file"
            
            echo_error "Failed to download image: $image after multiple attempts"
            ((failed++))
        fi
        
        # Update status file
        update_status "downloading" $completed $total
    done
    
    # Add summary statistics to the summary file
    jq --arg total "$total" \
       --arg completed "$completed" \
       --arg failed "$failed" \
       --arg timestamp "$(date +"%Y-%m-%dT%H:%M:%S%z")" \
       --arg bucket "$GCS_BUCKET" \
       '. += {"summary": {"total": $total, "completed": $completed, "failed": $failed, "timestamp": $timestamp, "bucket": $bucket}}' \
       "$summary_file" > "$summary_file.tmp" && sudo mv "$summary_file.tmp" "$summary_file"
    
    echo_info "Timing summary saved to $summary_file"
    
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

# Check for required tools
check_required_tools() {
    echo_info "Checking for required tools..."
    
    # Define required commands
    local required_commands=("curl" "jq" "aria2c")
    local missing_commands=()
    
    # Check each command
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    # Report missing commands
    if [ ${#missing_commands[@]} -gt 0 ]; then
        echo_error "Missing required tools: ${missing_commands[*]}"
        echo_error "Please run oneshot.sh first to install required dependencies."
        return 1
    fi
    
    echo_info "All required tools are available"
    return 0
}

# Main function
main() {
    echo_info "Starting Docker image prestaging process"
    
    # Initialize log file
    init_log_file
    
    # Check for required tools
    check_required_tools || exit 1
    
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
