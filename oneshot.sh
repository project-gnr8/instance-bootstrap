#!/bin/bash

# Enable debug mode to see what's happening
# set -x

# Define variables
INST_USER=$1
INST_DRIVER=$2
# Pass the metrics variables as a single string without adding extra quotes
INST_METRICS_VARS="$3"
# Pass the image list as a JSON string
IMAGE_LIST_JSON=${4:-'["nvcr.io/nvidia/rapidsai/notebooks:24.12-cuda12.5-py3.12"]'}
# GCS bucket for image storage
GCS_BUCKET=${5:-"brev-image-prestage"}
# Repository URL and branch for cloning
REPO_BRANCH=${6:-"main"}
REPO_URL="https://github.com/project-gnr8/instance-bootstrap.git"


# Define constants
SERVICE_NAME="instance-oneshot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

ENV_FILE="/etc/systemd/system/${SERVICE_NAME}.env"
PRESTAGE_SERVICE_NAME="docker-image-prestage"
PRESTAGE_SERVICE_FILE="/etc/systemd/system/${PRESTAGE_SERVICE_NAME}.service"
PRESTAGE_ENV_FILE="/etc/systemd/${PRESTAGE_SERVICE_NAME}.env"
SCRIPTS_DIR="/opt/instance-bootstrap"
PRESTAGE_SCRIPT="$SCRIPTS_DIR/image-prestage.sh"
IMPORT_SCRIPT="$SCRIPTS_DIR/image-import.sh"
PRESTAGE_STATUS_FILE="/opt/prestage/docker-images-prestage-status.json"
PRESTAGE_DIR="/opt/prestage/docker-images"

# Define log file path and key variables
user_home=$(eval echo ~$INST_USER)
LOG_FILE=${LOG_FILE:-"$user_home/.verb-setup.log"}
STARTUP_SCRIPT_URL=${STARTUP_SCRIPT_URL:-"https://raw.githubusercontent.com/project-gnr8/instance-bootstrap/refs/heads/main/startup.sh"}

# Function to initialize log file and directory
init_log_file() {
    # Create log directory first
    local log_dir=$(dirname "$LOG_FILE")
    
    # Check if log directory exists before creating
    if [ ! -d "$log_dir" ]; then
        echo "Creating log directory: $log_dir"
        sudo mkdir -p "$log_dir" 2>/dev/null
        sudo chmod 775 "$log_dir"
        sudo chown "$USER":"$USER" "$log_dir"
    fi
    
    # Then create/touch the log file if it doesn't exist
    if [ ! -f "$LOG_FILE" ]; then
        echo "Creating log file: $LOG_FILE"
        sudo touch "$LOG_FILE" 2>/dev/null
        sudo chown "$USER":"$USER" "$LOG_FILE"
        echo "[$( date +"%Y-%m-%dT%H:%M:%S%z" )] [INFO] Log initialized at $LOG_FILE" >> "$LOG_FILE"
    fi
}

# Enhanced logging functions for consistent output
echo_info() {
    local message="$1"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    
    # Format for console with colors
    printf "\033[1;34m[INFO]\033[0m [%s] %s\n" "$timestamp" "$message" >&1
    # Format for log file (without colors)
    printf "[%s] [INFO] %s\n" "$timestamp" "$message" >> "$LOG_FILE"
}

echo_error() {
    local message="$1"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    
    # Format for console with colors
    printf "\033[1;31m[ERROR]\033[0m [%s] %s\n" "$timestamp" "$message" >&1
    # Format for log file (without colors)
    printf "[%s] [ERROR] %s\n" "$timestamp" "$message" >> "$LOG_FILE"
}

echo_success() {
    local message="$1"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    
    # Format for console with colors
    printf "\033[1;32m[SUCCESS]\033[0m [%s] %s\n" "$timestamp" "$message" >&1
    # Format for log file (without colors)
    printf "[%s] [SUCCESS] %s\n" "$timestamp" "$message" >> "$LOG_FILE"
}

# Install required packages for all scripts
install_required_packages() {
    echo_info "Installing required packages for all scripts"
    
    # Define packages and their corresponding commands
    declare -A pkg_commands=(
        ["git"]="git"
        ["curl"]="curl"
        ["jq"]="jq"
        ["aria2"]="aria2c"
    )
    
    # Check which packages are already installed
    local packages_to_install=()
    for pkg in "${!pkg_commands[@]}"; do
        if ! command -v "${pkg_commands[$pkg]}" &>/dev/null; then
            packages_to_install+=("$pkg")
        else
            echo_info "${pkg_commands[$pkg]} is already installed"
        fi
    done
    
    # Install missing packages if any
    if [ ${#packages_to_install[@]} -gt 0 ]; then
        echo_info "Installing packages: ${packages_to_install[*]}"
        if sudo apt-get update -y > /dev/null && 
           sudo apt-get install -y "${packages_to_install[@]}" > /dev/null; then
            echo_success "Package installation completed successfully"
        else
            echo_error "Failed to install some packages"
            return 1
        fi
    else
        echo_info "All required packages are already installed"
    fi
    
    return 0
}

# Check if service is already running or has completed
check_service_status() {
    # Get detailed status information without hanging
    local is_active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "inactive")
    local is_enabled=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo "disabled")
    local is_failed=$(systemctl is-failed "$SERVICE_NAME" 2>/dev/null || echo "failed")
    local active_state=$(systemctl show -p ActiveState --value "$SERVICE_NAME" 2>/dev/null || echo "unknown")
    local sub_state=$(systemctl show -p SubState --value "$SERVICE_NAME" 2>/dev/null || echo "unknown")
    
    echo_info "Service state: $is_active (${active_state}/${sub_state})"
    
    if [ "$is_active" = "active" ] && [ "$sub_state" = "running" ]; then
        # Only consider it running if it's actually in running state
        echo_info "Service $SERVICE_NAME is currently running"
        return 0
    elif [ "$is_active" = "active" ] && [ "$sub_state" = "exited" ]; then
        # Handle the "active (exited)" state for oneshot services
        echo_info "Service $SERVICE_NAME has already completed successfully"
        return 0
    elif [ "$is_enabled" = "enabled" ] && [ "$is_failed" != "failed" ]; then
        # Service is enabled but not active - could be waiting to start
        echo_info "Service $SERVICE_NAME is configured but not currently active"
        return 0
    fi
    
    # Service needs to be configured
    return 1
}

# Check if prestage service is configured
is_prestage_service_configured() {
    # Check if service file exists
    if [ ! -f "$PRESTAGE_SERVICE_FILE" ]; then
        return 1
    fi
    
    # Check if service is enabled
    if ! systemctl is-enabled "$PRESTAGE_SERVICE_NAME" &>/dev/null; then
        return 1
    fi
    
    # Check if environment file exists
    if [ ! -f "$PRESTAGE_ENV_FILE" ]; then
        return 1
    fi
    
    return 0
}

# Check if prestage scripts are installed
is_prestage_scripts_installed() {
    # Check if prestage script exists
    if [ ! -f "$PRESTAGE_SCRIPT" ]; then
        return 1
    fi
    
    # Check if import script exists
    if [ ! -f "$IMPORT_SCRIPT" ]; then
        return 1
    fi
    
    # Check if scripts are executable
    if [ ! -x "$PRESTAGE_SCRIPT" ] || [ ! -x "$IMPORT_SCRIPT" ]; then
        return 1
    fi
    
    return 0
}

# Download a file from a URL
download_file() {
    local url=$1
    local destination=$2
    local description=$3
    
    if [ -z "$url" ]; then
        echo_info "No URL provided for $description. Skipping download."
        return 0
    fi
    
    echo_info "Downloading $description from $url to $destination"
    
    # Create directory if it doesn't exist
    local dir=$(dirname "$destination")
    if [ ! -d "$dir" ]; then
        sudo mkdir -p "$dir"
    fi
    
    # Download the file using appropriate method based on URL type
    if [[ "$url" == http://* ]] || [[ "$url" == https://* ]]; then
        # Standard HTTP/HTTPS URL - use curl
        sudo curl -sSL "$url" -o "$destination"
    else
        # For all other URLs (including gs:// URLs), use aria2c for better performance
        echo_info "Using aria2c for download"
        aria2c --file-allocation=none \
               --max-connection-per-server=16 \
               --dir="$(dirname "$destination")" \
               --out="$(basename "$destination")" \
               "$url"
    fi
    
    # Set permissions
    sudo chmod 755 "$destination"
    
    echo_info "$description downloaded successfully"
    return 0
}

# Clone repository and stage scripts
clone_and_stage_scripts() {
    local repo_url=$1
    local branch=$2
    
    if [ -z "$repo_url" ]; then
        echo_info "No repository URL provided. Skipping clone operation."
        return 0
    fi
    
    echo_info "Cloning repository from $repo_url (branch: $branch)"
    
    # Remove existing directory if it exists to ensure clean clone
    if [ -d "$SCRIPTS_DIR" ]; then
        echo_info "Removing existing scripts directory"
        sudo rm -rf "$SCRIPTS_DIR"
    fi
    
    # Clone the repository
    echo_info "Cloning repository to $SCRIPTS_DIR"
    sudo git clone --depth 1 --branch "$branch" "$repo_url" "$SCRIPTS_DIR" 2>/dev/null || 
        sudo git clone --depth 1 "$repo_url" "$SCRIPTS_DIR"
    
    if [ $? -ne 0 ]; then
        echo_error "Failed to clone repository. Falling back to local scripts."
        return 1
    fi
    
    # Make all shell scripts executable
    echo_info "Making scripts executable"
    sudo find "$SCRIPTS_DIR" -name "*.sh" -exec chmod 777 {} \;
    
    # Make service files readable
    sudo find "$SCRIPTS_DIR" -name "*.service" -exec chmod 644 {} \;
    
    echo_info "Scripts staged successfully from repository"
    return 0
}

# Setup the image prestaging service
setup_prestage_service() {
    echo_info "Setting up Docker image prestaging service"
    
    # Check if all required files exist
    if [ ! -f "$PRESTAGE_SCRIPT" ] || [ ! -f "$IMPORT_SCRIPT" ]; then
        echo_error "Missing required scripts for image prestaging. Skipping service setup."
        return 1
    fi
    
    # Ensure scripts are executable
    echo_info "Setting executable permissions on prestage scripts"
    sudo chmod +x "$PRESTAGE_SCRIPT" "$IMPORT_SCRIPT"
    
    # Create environment file with variables
    echo_info "Creating environment file for prestaging service"
    
    # Create directory for environment file if it doesn't exist
    sudo mkdir -p "$(dirname "$PRESTAGE_ENV_FILE")"
    
    echo "INST_USER=${INST_USER}" | sudo tee "$PRESTAGE_ENV_FILE" > /dev/null
    
    # Handle JSON properly - strip any outer quotes first, then add them consistently
    # This prevents double-quoting issues when the variable is expanded in the service
    local cleaned_json=$(echo "$IMAGE_LIST_JSON" | sed "s/^'\\(.*\\)'$/\\1/")
    echo "IMAGE_LIST_JSON='${cleaned_json}'" | sudo tee -a "$PRESTAGE_ENV_FILE" > /dev/null
    
    echo "GCS_BUCKET=${GCS_BUCKET}" | sudo tee -a "$PRESTAGE_ENV_FILE" > /dev/null
    sudo chmod 600 "$PRESTAGE_ENV_FILE"
    
    # Verify environment file was created
    if [ ! -f "$PRESTAGE_ENV_FILE" ]; then
        echo_error "Failed to create environment file: $PRESTAGE_ENV_FILE"
        return 1
    fi
    
    # Create prestage directory with proper permissions
    echo_info "Creating prestage directory"
    sudo mkdir -p "$PRESTAGE_DIR"
    sudo chown -R "$INST_USER":"$INST_USER" "$PRESTAGE_DIR"
    
    # Copy systemd service file
    echo_info "Installing systemd service file"
    sudo cp "$PRESTAGE_SERVICE_FILE" "/etc/systemd/system/${PRESTAGE_SERVICE_NAME}.service"
    
    # Reload systemd to pick up the new service
    echo_info "Reloading systemd daemon"
    sudo systemctl daemon-reload
    
    # Enable and start the service
    echo_info "Enabling and starting prestage service"
    sudo systemctl enable "$PRESTAGE_SERVICE_NAME.service"
    
    # Start the service in the background
    sudo systemctl start "$PRESTAGE_SERVICE_NAME.service" &
    
    # Give the service a moment to start
    sleep 2
    
    # Check if the service is enabled first
    if ! sudo systemctl is-enabled --quiet "$PRESTAGE_SERVICE_NAME.service"; then
        echo_error "Failed to enable docker-image-prestage service"
        return 1
    fi
    
    # Check service status - don't fail on non-zero exit code
    service_status=$(sudo systemctl status "$PRESTAGE_SERVICE_NAME.service" 2>&1 || true)
    
    # Check for common success indicators in the status output
    if echo "$service_status" | grep -q "Active: active"; then
        echo_success "Docker image prestaging service is active and running"
    elif echo "$service_status" | grep -q "starting Docker image prestaging"; then
        echo_success "Docker image prestaging service has started successfully"
    elif echo "$service_status" | grep -q "Starting Docker Image Prestaging"; then
        echo_success "Docker image prestaging service is starting"
    else
        # Service might have failed, but we'll continue anyway and just log a warning
        echo_info "Docker image prestaging service status is unclear. This is normal for long-running tasks."
        echo_info "You can check the status with: journalctl -u $PRESTAGE_SERVICE_NAME"
    fi
    
    # Create a status file to track download progress if it doesn't exist
    echo_info "Ensuring status file exists"
    local status_file="$PRESTAGE_DIR/docker-images-prestage-status.json"
    if [ ! -f "$status_file" ]; then
        echo '{"status":"pending","completed":0,"total":0,"images":[]}' | sudo tee "$status_file" > /dev/null
        sudo chown "$INST_USER":"$INST_USER" "$status_file"
    fi
    
    echo_info "Docker image prestaging service setup completed"
    return 0
}

# Setup and start the systemd service
setup_service() {
    echo_info "Setting up instance oneshot service"
    
    # Create environment file with variables
    echo_info "Creating environment file for oneshot service"
    echo "INST_USER=${INST_USER}" | sudo tee "$ENV_FILE" > /dev/null
    echo "INST_DRIVER=${INST_DRIVER}" | sudo tee -a "$ENV_FILE" > /dev/null
    echo "INST_METRICS_VARS='${INST_METRICS_VARS}'" | sudo tee -a "$ENV_FILE" > /dev/null
    echo "IMAGE_LIST_JSON='${IMAGE_LIST_JSON}'" | sudo tee -a "$ENV_FILE" > /dev/null
    echo "GCS_BUCKET=${GCS_BUCKET}" | sudo tee -a "$ENV_FILE" > /dev/null
    sudo chmod 600 "$ENV_FILE"
    
    # Create service file
    echo_info "Creating systemd service file for oneshot service"
    cat << EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Instance Oneshot Configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/systemd/system/${SERVICE_NAME}.env
ExecStart=$SCRIPTS_DIR/startup.sh \${INST_USER} \${INST_DRIVER} \${INST_METRICS_VARS} \${IMAGE_LIST_JSON} \${GCS_BUCKET}
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd, enable and start the service
    echo_info "Reloading systemd configuration"
    sudo systemctl daemon-reload
    
    echo_info "Enabling and starting $SERVICE_NAME service"
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl start "$SERVICE_NAME"
    
    # Check service status
    echo_info "Checking service status"
    if ! systemctl is-active "$SERVICE_NAME" > /dev/null 2>&1; then
        echo_error "Service failed to start. Check logs for details."
        echo_info "To view logs, run: sudo journalctl -u $SERVICE_NAME"
        return 1
    fi
    
    echo_info "Service started successfully"
    echo_info "To view complete logs at any time, run: sudo journalctl -u $SERVICE_NAME"
}


# Main function
main() {
    # Initialize log file
    init_log_file
    
    echo_info "Starting instance bootstrap oneshot script"
    
    # Print startup information
    echo_info "User: $INST_USER"
    echo_info "Image List: $IMAGE_LIST_JSON"
    echo_info "GCS Bucket: $GCS_BUCKET"
    echo_info "Repository URL: $REPO_URL"
    echo_info "Repository Branch: $REPO_BRANCH"
    
    # Install required packages first
    install_required_packages || echo_error "Some packages failed to install, but continuing"
    
    # Clone repository and stage scripts if URL is provided
    if [ -n "$REPO_URL" ]; then
        clone_and_stage_scripts "$REPO_URL" "$REPO_BRANCH"
    fi
    
    # Setup image prestaging service first to allow it to run in the background
    if ! is_prestage_service_configured; then
        if [ "$IMAGE_LIST_JSON" != "[]" ]; then
            echo_info "Setting up image prestaging service"
            setup_prestage_service
        else
            echo_info "No images specified for prestaging. Skipping prestage service setup."
        fi
    else
        echo_info "Image prestaging service is already configured. Skipping configuration."
    fi
    
    # Check if service already exists and is running/completed
    if check_service_status; then
        echo_info "Service already configured, showing status summary"
        # Use systemctl show instead of status to avoid hanging
        echo_info "Service status details:"
        systemctl show "$SERVICE_NAME" -p LoadState,ActiveState,SubState,UnitFileState,Result
        echo_info "Instance bootstrap oneshot script completed - service already configured"
        return 0
    else
        # Stop and disable service if it exists but failed
        if systemctl list-unit-files "$SERVICE_NAME.service" | grep -q "$SERVICE_NAME"; then
            echo_info "Cleaning up existing failed service"
            sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
            sudo rm -f "$SERVICE_FILE" 2>/dev/null || true
            sudo systemctl daemon-reload
            sudo systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
        fi
        
        # Setup oneshot service
        setup_service
    fi
    
    echo_info "Oneshot configuration completed successfully"
    return 0
}

# Execute main function
main

# Ensure script exits cleanly
exit 0
