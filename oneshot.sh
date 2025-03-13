#!/bin/bash

set -x

# Define log file path (can be overridden before sourcing)
LOG_FILE=${LOG_FILE:-"/var/log/instance-bootstrap/oneshot.log"}
STARTUP_SCRIPT_URL=${STARTUP_SCRIPT_URL:-"https://raw.githubusercontent.com/project-gnr8/instance-bootstrap/refs/heads/main/startup.sh"}
SERVICE_NAME="instance-oneshot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

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
    echo -e "$console_msg" | tee >(echo "$log_msg" >> "$LOG_FILE")
}

is_service_configured() {
    # Check if service file exists and has correct content
    if [ -f "$SERVICE_FILE" ]; then
        echo_info "Service file already exists: $SERVICE_FILE"
        return 0
    fi
    return 1
}

is_startup_script_installed() {
    # Check if startup script exists and is executable
    if [ -f "/opt/startup.sh" ] && [ -x "/opt/startup.sh" ]; then
        echo_info "Startup script already installed at /opt/startup.sh but refreshing."
        return 1
    fi
    return 1
}

is_service_enabled() {
    # Check if service is enabled
    if sudo systemctl is-enabled "$SERVICE_NAME" &>/dev/null; then
        echo_info "Service $SERVICE_NAME is already enabled"
        return 0
    fi
    return 1
}

is_service_active_or_done() {
    # Check if service is active or has completed successfully
    local status=$(sudo systemctl is-active "$SERVICE_NAME" 2>/dev/null)
    local failed=$(sudo systemctl is-failed "$SERVICE_NAME" 2>/dev/null)
    
    if [ "$status" = "active" ] || [ "$failed" = "active" ]; then
        echo_info "Service $SERVICE_NAME is already running"
        return 0
    elif [ "$status" = "inactive" ] && [ "$failed" != "failed" ]; then
        echo_info "Service $SERVICE_NAME has already completed successfully"
        return 0
    fi
    return 1
}

init_systemd_oneshot() {
    # Check if service is already properly configured and running
    if is_service_configured && is_startup_script_installed && is_service_enabled && is_service_active_or_done; then
        echo_info "Service $SERVICE_NAME is already properly configured and running/completed"
        return 0
    fi

    echo_info "Defining $SERVICE_NAME service"

    # Create env file for sensitive variables
    local env_file="/etc/systemd/$SERVICE_NAME.env"
    echo "Creating environment file for sensitive variables"
    echo "INST_USER=${INST_USER}" | sudo tee "$env_file" > /dev/null
    echo "INST_DRIVER=${INST_DRIVER}" | sudo tee -a "$env_file" > /dev/null
    echo "INST_METRICS_VARS=${INST_METRICS_VARS}" | sudo tee -a "$env_file" > /dev/null
    sudo chmod 600 "$env_file"

    # Create service file content
    local service_content="[Unit]
Description=Instance Oneshot Configuration
After=network.target

[Service]
Type=oneshot
EnvironmentFile=${env_file}
ExecStart=/opt/startup.sh \${INST_USER} \${INST_DRIVER} \"\${INST_METRICS_VARS}\"
StandardOutput=journal
StandardError=journal
# Kill all processes in the control group to ensure cleanup
KillMode=control-group
# Set TimeoutStopSec to a higher value to allow proper cleanup
TimeoutStopSec=180s
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"

    # Write service file using sudo tee instead of redirection
    echo "$service_content" | sudo tee "$SERVICE_FILE" > /dev/null

    echo_info "Downloading $STARTUP_SCRIPT_URL"
    sudo curl -sSL -H 'Cache-Control: no-cache' "$STARTUP_SCRIPT_URL" -o /opt/startup.sh
    sudo chmod a+x /opt/startup.sh
    sudo chmod 644 "$SERVICE_FILE"
    sudo systemctl daemon-reload
    
    if ! is_service_enabled; then
        echo_info "Enabling $SERVICE_NAME service"
        sudo systemctl enable "$SERVICE_NAME"
    fi

    if ! is_service_active_or_done; then
        echo_info "Starting $SERVICE_NAME service"
        sudo systemctl start "$SERVICE_NAME"
    fi
}

stream_service_logs_until_complete() {
    echo_info "Streaming logs from $SERVICE_NAME service until completion..."
    
    # Check if service is already completed
    local status=$(sudo systemctl is-active "$SERVICE_NAME" 2>/dev/null)
    local failed=$(sudo systemctl is-failed "$SERVICE_NAME" 2>/dev/null)
    
    if [ "$status" = "inactive" ] && [ "$failed" != "failed" ]; then
        echo_info "Service $SERVICE_NAME has already completed successfully"
        check_service_status
        return 0
    fi
    
    # Start a background process to stream logs
    sudo journalctl -f -u "$SERVICE_NAME" --no-pager &
    JOURNALCTL_PID=$!
    
    # Check service status in a loop until it's completed or failed
    while true; do
        # Get the current status of the service
        STATUS=$(sudo systemctl is-active "$SERVICE_NAME" 2>/dev/null)
        
        if [ "$STATUS" = "active" ]; then
            # Service is still running, wait and check again
            sleep 2
        else
            # Service has completed (successfully or with failure)
            # Get the final status
            FINAL_STATUS=$(sudo systemctl is-failed "$SERVICE_NAME" 2>/dev/null)
            
            if [ "$FINAL_STATUS" = "failed" ]; then
                echo_info "Service completed with FAILURE"
                sudo systemctl status "$SERVICE_NAME"
            else
                echo_info "Service completed SUCCESSFULLY"
            fi
            
            # Kill the journalctl process
            kill $JOURNALCTL_PID 2>/dev/null
            wait $JOURNALCTL_PID 2>/dev/null
            break
        fi
    done
    
    echo_info "To view complete logs at any time, run:"
    echo_info "sudo journalctl -u $SERVICE_NAME"
}

check_service_status() {
    echo_info "Checking $SERVICE_NAME service status..."
    sudo systemctl status "$SERVICE_NAME"
    
    echo_info "To view complete logs at any time, run:"
    echo_info "sudo journalctl -u $SERVICE_NAME"
}

# Main execution flow
# Initialize log file at script start
init_log_file
init_systemd_oneshot

# Stream logs until service completes instead of just checking status
stream_service_logs_until_complete
