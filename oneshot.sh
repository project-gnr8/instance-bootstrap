#!/bin/bash

#set -x

# Define log file path (can be overridden before sourcing)
LOG_FILE=${LOG_FILE:-"/var/log/instance-bootstrap/oneshot.log"}
STARTUP_SCRIPT_URL=${STARTUP_SCRIPT_URL:-"https://github.com/project-gnr8/instance-bootstrap/main/startup.sh"}

INST_USER=$1
INST_DRIVER=$2
INST_METRICS_VARS="aws_timestream_access_key='$3' aws_timestream_secret_key='$4' aws_timestream_database='$5' aws_timestream_region='$6' environmentID='$7'"

# Function to initialize log file and directory
init_log_file() {
    # Create log directory first
    local log_dir=$(dirname "$LOG_FILE")
    sudo mkdir -p "$log_dir" 2>/dev/null
    
    # Then create/touch the log file
    sudo touch "$LOG_FILE" 2>/dev/null
    sudo chmod 775 "$log_dir"
    sudo chown "$USER":"$USER" "$log_dir"
    sudo chown "$USER":"$USER" $LOG_FILE
    echo "[$( date +"%Y-%m-%dT%H:%M:%S%z" )] [INFO] Log initialized at $LOG_FILE" >> "$LOG_FILE"
}

echo_info() {
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    # Format for console (with colors)
    local console_msg="\033[1;34m[INFO]\033[0m [$timestamp] $1"
    # Format for log file (without colors)
    local log_msg="[$timestamp] [INFO] $1"
    # Output to console and log file using tee
    echo -e "$console_msg" | tee >(echo "$log_msg" >> "$LOG_FILE") >/dev/null
}

init_systemd_oneshot() {
    echo_info "Defining instance-oneshot.service"
    sudo cat <<EOF > /etc/systemd/system/instance-oneshot.service
[Unit]
Description=Instance Oneshot Configuration
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/startup.sh $INST_USER $INST_DRIVER "$INST_METRICS_VARS"
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    echo_info "Downloading $STARTUP_SCRIPT_URL"
    sudo curl -sSL $STARTUP_SCRIPT_URL -o /opt/startup.sh
    sudo chmod a+x /opt/startup.sh
    sudo chmod 644 /etc/systemd/system/instance-oneshot.service
    sudo systemctl daemon-reload
    sudo systemctl enable instance-oneshot

    echo_info "Starting instance-oneshot.service"
    sudo systemctl start instance-oneshot
}

stream_service_logs_until_complete() {
    echo_info "Streaming logs from instance-oneshot service until completion..."
    
    # Start a background process to stream logs
    sudo journalctl -f -u instance-oneshot --no-pager &
    JOURNALCTL_PID=$!
    
    # Check service status in a loop until it's completed or failed
    while true; do
        # Get the current status of the service
        STATUS=$(sudo systemctl is-active instance-oneshot 2>/dev/null)
        
        if [ "$STATUS" = "active" ]; then
            # Service is still running, wait and check again
            sleep 2
        else
            # Service has completed (successfully or with failure)
            # Get the final status
            FINAL_STATUS=$(sudo systemctl is-failed instance-oneshot 2>/dev/null)
            
            if [ "$FINAL_STATUS" = "failed" ]; then
                echo_info "Service completed with FAILURE"
                sudo systemctl status instance-oneshot
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
    echo_info "sudo journalctl -u instance-oneshot"
}

check_service_status() {
    echo_info "Checking instance-oneshot service status..."
    sudo systemctl status instance-oneshot
    
    echo_info "To view complete logs at any time, run:"
    echo_info "sudo journalctl -u instance-oneshot"
}

# Initialize log file at script start
init_log_file
init_systemd_oneshot

# Stream logs until service completes instead of just checking status
stream_service_logs_until_complete
