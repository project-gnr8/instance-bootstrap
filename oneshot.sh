#!/bin/bash

# Strict mode to catch errors early
set -euo pipefail

# Define log file path and key variables
LOG_FILE=${LOG_FILE:-"/var/log/instance-bootstrap/oneshot.log"}
STARTUP_SCRIPT_URL=${STARTUP_SCRIPT_URL:-"https://raw.githubusercontent.com/project-gnr8/instance-bootstrap/refs/heads/main/startup.sh"}
SERVICE_NAME="instance-oneshot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="/etc/systemd/${SERVICE_NAME}.env"

# Parse command line arguments
INST_USER=${1:-"ubuntu"}
INST_DRIVER=${2:-"535"}
INST_METRICS_VARS="${3:-""}"

# Function to initialize log file and directory
init_log_file() {
    local log_dir=$(dirname "$LOG_FILE")
    
    # Create log directory if it doesn't exist
    if [ ! -d "$log_dir" ]; then
        sudo mkdir -p "$log_dir" 2>/dev/null
        sudo chmod 775 "$log_dir"
        sudo chown "$USER":"$USER" "$log_dir"
    fi
    
    # Create log file if it doesn't exist
    if [ ! -f "$LOG_FILE" ]; then
        sudo touch "$LOG_FILE" 2>/dev/null
        sudo chown "$USER":"$USER" "$LOG_FILE"
    fi
    
    echo "[$( date +"%Y-%m-%dT%H:%M:%S%z" )] [INFO] Log initialized at $LOG_FILE" >> "$LOG_FILE"
}

# Enhanced logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    
    # Format for console with colors
    local color=""
    case "$level" in
        "INFO") color="\033[1;34m" ;;
        "ERROR") color="\033[1;31m" ;;
        "SUCCESS") color="\033[1;32m" ;;
        *) color="\033[1;34m" ;;
    esac
    
    # Output to console and log file
    printf "${color}[%s]\033[0m [%s] %s\n" "$level" "$timestamp" "$message" >&1
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
}

# Check if service is already running or has completed
check_service_state() {
    # Get current status
    local is_active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "inactive")
    local is_enabled=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo "disabled")
    local is_failed=$(systemctl is-failed "$SERVICE_NAME" 2>/dev/null || echo "no")
    
    # Return status code based on service state
    if [ "$is_active" = "active" ]; then
        # Service is currently running
        return 1
    elif [ "$is_active" = "inactive" ] && [ "$is_enabled" = "enabled" ] && [ "$is_failed" != "failed" ]; then
        # Service has completed successfully
        return 0
    else
        # Service needs setup
        return 2
    fi
}

# Clean up any existing service artifacts to ensure clean state
cleanup_service() {
    log "INFO" "Cleaning up existing service artifacts"
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "$SERVICE_FILE" "$ENV_FILE" 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
}

# Configure and start the systemd service
setup_service() {
    log "INFO" "Setting up $SERVICE_NAME service"
    
    # Create environment file with sensitive variables
    log "INFO" "Creating environment file for service variables"
    sudo tee "$ENV_FILE" > /dev/null << EOF
INST_USER=${INST_USER}
INST_DRIVER=${INST_DRIVER}
INST_METRICS_VARS=${INST_METRICS_VARS}
EOF
    sudo chmod 600 "$ENV_FILE"
    
    # Download the startup script
    log "INFO" "Downloading startup script from $STARTUP_SCRIPT_URL"
    sudo curl -sSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "$STARTUP_SCRIPT_URL?$(date +%s)" -o /opt/startup.sh
    sudo chmod 755 /opt/startup.sh
    
    # Create service file
    log "INFO" "Creating systemd service file"
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Instance Oneshot Configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
ExecStart=/opt/startup.sh \${INST_USER} \${INST_DRIVER} "\${INST_METRICS_VARS}"
StandardOutput=journal
StandardError=journal
KillMode=process
TimeoutStartSec=0
TimeoutStopSec=180s
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 644 "$SERVICE_FILE"
    
    # Reload systemd, enable and start the service
    log "INFO" "Reloading systemd configuration"
    sudo systemctl daemon-reload
    
    log "INFO" "Enabling and starting $SERVICE_NAME service"
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl start "$SERVICE_NAME"
}

# Stream service logs with proper termination
stream_logs() {
    log "INFO" "Streaming service logs (press Ctrl+C to stop)..."
    
    # Start journalctl in the background
    sudo journalctl -f -u "$SERVICE_NAME" --no-pager &
    local journal_pid=$!
    
    # Trap to ensure we clean up the background process
    trap 'kill $journal_pid 2>/dev/null; wait $journal_pid 2>/dev/null; exit' INT TERM EXIT
    
    # Monitor service status
    local max_wait=1800  # 30 minutes timeout
    local waited=0
    local check_interval=5
    
    while [ $waited -lt $max_wait ]; do
        local status=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "inactive")
        
        if [ "$status" = "inactive" ]; then
            # Service has completed
            local exit_status=$(systemctl is-failed "$SERVICE_NAME" 2>/dev/null || echo "no")
            if [ "$exit_status" = "failed" ]; then
                log "ERROR" "Service failed to complete successfully"
                sudo systemctl status "$SERVICE_NAME"
            else
                log "SUCCESS" "Service completed successfully"
            fi
            break
        fi
        
        # Wait before checking again
        sleep $check_interval
        waited=$((waited + check_interval))
    done
    
    # If we've timed out, report it
    if [ $waited -ge $max_wait ]; then
        log "ERROR" "Service monitoring timed out after $max_wait seconds"
    fi
    
    # Clean up the journalctl process
    kill $journal_pid 2>/dev/null
    wait $journal_pid 2>/dev/null
    trap - INT TERM EXIT
    
    log "INFO" "To view complete logs at any time, run: sudo journalctl -u $SERVICE_NAME"
}

# Main execution flow
main() {
    # Initialize logging
    init_log_file
    log "INFO" "Starting instance bootstrap oneshot script"
    
    # Check current service state
    check_service_state
    local service_state=$?
    
    case $service_state in
        0)  # Service has completed successfully
            log "SUCCESS" "Service has already completed successfully"
            sudo systemctl status "$SERVICE_NAME"
            ;;
        1)  # Service is currently running
            log "INFO" "Service is currently running, streaming logs"
            stream_logs
            ;;
        2)  # Service needs setup
            log "INFO" "Setting up and starting service"
            cleanup_service
            setup_service
            stream_logs
            ;;
    esac
    
    log "INFO" "Instance bootstrap oneshot script completed"
}

# Execute main function
main "$@"
