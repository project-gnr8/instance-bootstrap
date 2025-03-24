#!/bin/bash

# Enable strict mode
set -euo pipefail

# Parse command line arguments
INST_USER=$1
STATUS_FILE=${2:-"/opt/prestage/docker-images-prestage-status.json"}
PRESTAGE_DIR=${3:-"/opt/prestage/docker-images"}
FORCE_IMPORT=${4:-"false"}

user_home=$(eval echo ~$INST_USER)
LOG_FILE=${LOG_FILE:-"$user_home/.verb-setup.log"}

# Image name to GCS object mapping
# This maps Docker image names to their corresponding GCS object names
# Must be kept in sync with image-prestage.sh
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

# Timing function to track operation duration
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

# Get file size in human-readable format
get_file_size() {
    local file=$1
    if [ -f "$file" ]; then
        du -h "$file" | cut -f1
    else
        echo "unknown"
    fi
}

# Calculate transfer rate
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

# Get the correct tar filename for an image
get_tar_filename() {
    local image=$1
    
    # Check if we have a custom mapping for this image
    if [[ -n "${IMAGE_TO_OBJECT_MAP[$image]:-}" ]]; then
        # Use the object name directly as the filename
        local object_name="${IMAGE_TO_OBJECT_MAP[$image]}"
        echo "$PRESTAGE_DIR/$object_name"
    else
        # Fallback to the default naming convention
        local safe_name=$(echo "$image" | tr '/:' '_-')
        echo "$PRESTAGE_DIR/${safe_name}.tar"
    fi
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
    
    # Check status unless force flag is set
    if [ "$FORCE_IMPORT" != "true" ]; then
        local status=$(jq -r '.status' "$STATUS_FILE" 2>/dev/null || echo "unknown")
        if [ "$status" != "completed" ] && [ "$status" != "completed_with_errors" ]; then
            echo_error "Image prestaging not completed. Current status: $status"
            echo_info "Use force flag (4th argument) to bypass this check for testing"
            return 1
        fi
    else
        echo_info "Force flag set - bypassing status check"
    fi
    
    # Get image list
    local images=$(jq -r '.images | .[]' "$STATUS_FILE")
    local total=$(jq -r '.total' "$STATUS_FILE")
    local completed=0
    local failed=0
    
    echo_info "Found $total images to import"
    
    # Create a summary file for timing data
    local summary_file="$PRESTAGE_DIR/import_timing_summary.json"
    echo '{"images":[]}' > "$summary_file"
    
    # Process each image
    for image in $images; do
        # Get the tar file path for this image
        local tar_file=$(get_tar_filename "$image")
        local safe_name=$(echo "$image" | tr '/:' '_-')
        
        echo_info "Processing image: $image (tar file: $tar_file)"
        
        if [ -f "$tar_file" ]; then
            echo_info "Importing image: $image from $tar_file"
            
            # Get file size before import
            local file_size_bytes=$(stat -c%s "$tar_file" 2>/dev/null || echo "unknown")
            local file_size_human=$(get_file_size "$tar_file")
            
            # Record start time
            local start_time=$(date +%s.%N)
            
            if docker load -i "$tar_file"; then
                # Record end time and calculate duration
                local end_time=$(date +%s.%N)
                local duration=$(echo "$end_time - $start_time" | bc)
                
                # Calculate transfer rate
                local transfer_rate=$(calculate_rate "$file_size_bytes" "$duration")
                
                # Log timing information
                echo_timing "docker_load_$image" "$duration" "$file_size_human" "$transfer_rate"
                
                # Add to summary JSON
                jq --arg img "$image" \
                   --arg duration "$duration" \
                   --arg size "$file_size_human" \
                   --arg rate "$transfer_rate" \
                   '.images += [{"image": $img, "operation": "docker_load", "duration": $duration, "size": $size, "rate": $rate}]' \
                   "$summary_file" > "$summary_file.tmp" && mv "$summary_file.tmp" "$summary_file"
                
                echo_success "Successfully imported image: $image"
                ((completed++))
            else
                # Record end time and calculate duration even for failures
                local end_time=$(date +%s.%N)
                local duration=$(echo "$end_time - $start_time" | bc)
                
                # Log timing information for failed import
                echo_timing "docker_load_failed_$image" "$duration" "$file_size_human" "unknown"
                
                # Add to summary JSON
                jq --arg img "$image" \
                   --arg duration "$duration" \
                   --arg size "$file_size_human" \
                   '.images += [{"image": $img, "operation": "docker_load_failed", "duration": $duration, "size": $size, "rate": "unknown"}]' \
                   "$summary_file" > "$summary_file.tmp" && mv "$summary_file.tmp" "$summary_file"
                
                echo_error "Failed to import image: $image"
                ((failed++))
            fi
        else
            echo_error "Tar file not found for image: $image (expected at $tar_file)"
            ((failed++))
        fi
    done
    
    # Add summary statistics to the summary file
    jq --arg total "$total" \
       --arg completed "$completed" \
       --arg failed "$failed" \
       --arg timestamp "$(date +"%Y-%m-%dT%H:%M:%S%z")" \
       '. += {"summary": {"total": $total, "completed": $completed, "failed": $failed, "timestamp": $timestamp}}' \
       "$summary_file" > "$summary_file.tmp" && mv "$summary_file.tmp" "$summary_file"
    
    echo_info "Timing summary saved to $summary_file"
    
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
