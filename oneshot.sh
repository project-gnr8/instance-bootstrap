#!/bin/bash

# Enable debug mode to see what's happening
set -x

# Define log file path and key variables
LOG_FILE=${LOG_FILE:-"/var/log/instance-bootstrap/oneshot.log"}
STARTUP_SCRIPT_URL=${STARTUP_SCRIPT_URL:-"https://raw.githubusercontent.com/project-gnr8/instance-bootstrap/refs/heads/main/startup.sh"}
SERVICE_NAME="instance-oneshot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Parse command line arguments
INST_USER=$1
INST_DRIVER=$2
INST_METRICS_VARS="aws_timestream_access_key='$3' aws_timestream_secret_key='$4' aws_timestream_database='$5' aws_timestream_region='$6' environmentID='$7'"

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

echo_info() {
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    # Format for console (with colors)
    local console_msg="\033[1;34m[INFO]\033[0m [$timestamp] $1"
    # Format for log file (without colors)
    local log_msg="[$timestamp] [INFO] $1"
    # Output to console and log file using tee
    echo -e "$console_msg" | tee -a "$LOG_FILE"
}

echo_error() {
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    # Format for console (with colors)
    local console_msg="\033[1;31m[ERROR]\033[0m [$timestamp] $1"
    # Format for log file (without colors)
    local log_msg="[$timestamp] [ERROR] $1"
    # Output to console and log file using tee
    echo -e "$console_msg" | tee -a "$LOG_FILE"
}

# Check if service is already running or has completed
check_service_status() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo_info "Service $SERVICE_NAME is already running"
        return 0
    elif systemctl is-enabled --quiet "$SERVICE_NAME" && ! systemctl is-failed --quiet "$SERVICE_NAME"; then
        echo_info "Service $SERVICE_NAME has already completed successfully"
        return 0
    fi
    return 1
}

# Setup and start the systemd service
setup_service() {
    echo_info "Setting up $SERVICE_NAME service"
    
    # Create environment file with sensitive variables
    local env_file="/etc/systemd/$SERVICE_NAME.env"
    echo_info "Creating environment file for service variables"
    echo "INST_USER=${INST_USER}" | sudo tee "$env_file" > /dev/null
    echo "INST_DRIVER=${INST_DRIVER}" | sudo tee -a "$env_file" > /dev/null
    echo "INST_METRICS_VARS=${INST_METRICS_VARS}" | sudo tee -a "$env_file" > /dev/null
    sudo chmod 600 "$env_file"
    
    # Download the startup script
    echo_info "Downloading startup script from $STARTUP_SCRIPT_URL"
    sudo curl -sSL -H 'Cache-Control: no-cache' "$STARTUP_SCRIPT_URL?$(date +%s)" -o /opt/startup.sh
    sudo chmod 755 /opt/startup.sh
    
    # Create service file
    echo_info "Creating systemd service file"
    cat << EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Instance Oneshot Configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${env_file}
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
    echo_info "Reloading systemd configuration"
    sudo systemctl daemon-reload
    
    echo_info "Enabling and starting $SERVICE_NAME service"
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl start "$SERVICE_NAME"
}

# Stream service logs
stream_logs() {
    echo_info "Streaming service logs..."
    sudo journalctl -f -u "$SERVICE_NAME" --no-pager &
    JOURNAL_PID=$!
    
    # Wait for service to complete or fail with timeout
    local timeout=600  # 10 minutes timeout
    local elapsed=0
    local check_interval=5
    
    echo_info "Monitoring service status (timeout: ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        # Check if service is still active
        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
            echo_info "Service is no longer active, checking final status"
            break
        fi
        
        # Check if service is still running but in a different state
        local status=$(systemctl show -p ActiveState --value "$SERVICE_NAME")
        if [ "$status" != "active" ]; then
            echo_info "Service state changed to: $status"
            break
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        
        # Show progress every minute
        if [ $((elapsed % 60)) -eq 0 ]; then
            echo_info "Still waiting for service to complete... (${elapsed}s elapsed)"
        fi
    done
    
    # Kill the journalctl process
    kill $JOURNAL_PID 2>/dev/null
    wait $JOURNAL_PID 2>/dev/null
    
    # Check if we timed out
    if [ $elapsed -ge $timeout ]; then
        echo_error "Monitoring timed out after ${timeout}s. Service may still be running."
        echo_info "You can check status manually with: sudo systemctl status $SERVICE_NAME"
        return
    fi
    
    # Check final status
    if systemctl is-failed --quiet "$SERVICE_NAME"; then
        echo_error "Service failed to complete successfully"
        sudo systemctl status "$SERVICE_NAME"
    else
        echo_info "Service completed successfully"
    fi
    
    echo_info "To view complete logs at any time, run: sudo journalctl -u $SERVICE_NAME"
}

# Main execution flow
main() {
    # Initialize logging
    init_log_file
    echo_info "Starting instance bootstrap oneshot script"
    
    # Check if service already exists and is running/completed
    if check_service_status; then
        echo_info "Service already configured, showing status"
        sudo systemctl status "$SERVICE_NAME"
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
        
        # Setup and start service
        setup_service
        stream_logs
    fi
    
    echo_info "Instance bootstrap oneshot script completed"
}

# Execute main function
main
