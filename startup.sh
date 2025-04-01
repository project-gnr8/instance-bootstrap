#!/bin/bash

# Strict mode to catch errors and prevent forking issues
set -euo pipefail

INST_USER=$1
INST_DRIVER=$2
INST_METRICS_VARS="$3"
# Add support for image list argument
IMAGE_LIST_JSON=${4:-'["nvcr.io/nvidia/rapidsai/notebooks:24.12-cuda12.5-py3.12"]'}

# Define log file path (can be overridden before sourcing)
user_home=$(eval echo ~$INST_USER)
LOG_FILE=${LOG_FILE:-"$user_home/.verb-setup.log"}
PRIMARY_DNS="1.1.1.1"
BACKUP_DNS="8.8.8.8"
# Define image prestaging status file
PRESTAGE_STATUS_FILE="/opt/prestage/docker-images-prestage-status.json"
PRESTAGE_DIR="/opt/prestage/docker-images"
IMPORT_SCRIPT="/opt/image-import.sh"

# Initialize log file and set up proper logging
init_log_file() {
    # Create log directory first
    local log_dir=$(dirname "$LOG_FILE")
    sudo mkdir -p "$log_dir" 2>/dev/null
    
    # Then create/touch the log file
    sudo touch "$LOG_FILE" 2>/dev/null
    sudo chmod 775 "$log_dir"
    sudo chown "$INST_USER":"$INST_USER" "$log_dir"
    sudo chown "$INST_USER":"$INST_USER" "$LOG_FILE"
    echo "[$( date +"%Y-%m-%dT%H:%M:%S%z" )] [INFO] Log initialized at $LOG_FILE" >> "$LOG_FILE"
}

# Non-forking echo function 
echo_info() {
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    # Format for console (with colors)
    printf "\033[1;34m[INFO]\033[0m [%s] %s\n" "$timestamp" "$1" >&1
    # Format for log file (without colors)
    printf "[%s] [INFO] %s\n" "$timestamp" "$1" >> "$LOG_FILE"
}


log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

with_retry() {
	local max_attempts="$1"
	local delay="$2"
	local count=0
	local rc
	shift 2

	while true; do
		set +e
		"$@"
		rc="$?"
		set -e

		count="$((count+1))"

		if [[ "${rc}" -eq 0 ]]; then
			return 0
		fi

		if [[ "${max_attempts}" -le 0 ]] || [[ "${count}" -lt "${max_attempts}" ]]; then
			sleep "${delay}"
		else
			break
		fi
	done

	return 1
}

# Function to wait for apt lock to be free
wait_for_apt_lock() {
    local lock_file="/var/lib/dpkg/lock-frontend"
    local lock_wait_time=360  # Maximum wait time in seconds
    local interval=5          # Interval between checks in seconds
    local elapsed=0

    echo_info "Waiting for apt lock to be released..."

    while sudo fuser "$lock_file" >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$lock_wait_time" ]; then
            echo_info "Timeout waiting for apt lock to be released."
            return 1
        fi
        echo_info "Apt lock is currently held by another process. Waiting..."
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    return 0
}

disable_unattended_upgrades() {
    echo_info "Disabling unattended-upgrades..."
    set +e # Disable exit on error -- want to try all
	sudo systemctl stop unattended-upgrades
	sudo pkill --signal SIGKILL unattended-upgrades
	sudo systemctl disable unattended-upgrades
	sudo sed -i 's/Unattended-Upgrade "1"/Unattended-Upgrade "0"/g' /etc/apt/apt.conf.d/20auto-upgrades
	sudo apt-get purge unattended-upgrades -y
	sudo dpkg --configure -a
    set -e
}

update_dns() {
    echo_info "Updating DNS configuration..."
    # Path to the systemd-resolved configuration
    RESOLVED_CONF="/etc/systemd/resolved.conf"

    # Backup the current configuration file
    sudo cp $RESOLVED_CONF "${RESOLVED_CONF}.bak"

    # Set DNS servers in systemd-resolved configuration
    sudo sed -i "s/^#DNS=.*/DNS=${PRIMARY_DNS} ${BACKUP_DNS}/" $RESOLVED_CONF
    sudo sed -i "s/^#FallbackDNS=.*/FallbackDNS=/" $RESOLVED_CONF
    sudo sed -i "s/^#Domains=.*/Domains=/" $RESOLVED_CONF
    sudo sed -i "s/^#LLMNR=.*/LLMNR=no/" $RESOLVED_CONF
    sudo sed -i "s/^#MulticastDNS=.*/MulticastDNS=no/" $RESOLVED_CONF
    sudo sed -i "s/^#DNSSEC=.*/DNSSEC=no/" $RESOLVED_CONF
    sudo sed -i "s/^#DNSOverTLS=.*/DNSOverTLS=no/" $RESOLVED_CONF
    sudo sed -i "s/^#Cache=.*/Cache=yes/" $RESOLVED_CONF
    sudo sed -i "s/^#DNSStubListener=.*/DNSStubListener=yes/" $RESOLVED_CONF

    # Restart systemd-resolved to apply changes
    sudo systemctl restart systemd-resolved

    echo_info "DNS servers have been updated to ${PRIMARY_DNS} (primary) and ${BACKUP_DNS} (backup)."
}

install_metrics() {
    echo_info "Setting up metrics..."
    
    # The metrics script expects individual space-separated arguments
    # We need to pass them directly to bash -s without any array processing
    # curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | \
    curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/feat-telegraf-procstat/setup.sh | \
        bash -s -- $INST_METRICS_VARS
    
    echo_info "Metrics setup completed"
}

install_nvidia_driver() {
    if [ "$INST_DRIVER" = "disabled" ]; then
        echo_info "NVIDIA driver installation is disabled. Skipping..."
        return
    else
        echo_info "Installing NVIDIA driver..."
        desired_version=$INST_DRIVER
        # Attempt to get the currently used NVIDIA driver version
        current_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null) || current_version=""

        # Check if nvidia-smi command succeeded
        if [ -z "$current_version" ]; then
            echo_info "nvidia-smi command failed. This could indicate that NVIDIA drivers are not installed."
            echo_info "Proceeding with installation of nvidia-driver-$desired_version..."
            sudo apt update
            sudo apt install "nvidia-driver-$desired_version" -y
        else
            # Extract major version numbers for comparison
            current_major=$(echo $current_version | cut -d. -f1)
            desired_major=$(echo $desired_version | cut -d. -f1)
            
            # Compare versions
            if [ "$current_major" -lt "$desired_major" ]; then
                echo_info "Current NVIDIA driver version ($current_version) is older than $desired_version. Installing $desired_version..."
                sudo apt update
                sudo apt install "nvidia-driver-$desired_version" -y
            else
                echo_info "Current NVIDIA driver version ($current_version) is greater than or equal to $desired_version. Keeping the current version."
            fi
        fi
    fi
    # Required minimum version for nvidia-ctk (any 1.17.x or above)
    required_ctk_version="1.17"
    nvidia_ctk_needs_install=false
    current_ctk_version=""

    if command -v nvidia-ctk &>/dev/null; then
        # Extract version from nvidia-ctk (e.g. "v1.17.4" or "1.17.4")
        current_ctk_version=$(nvidia-ctk --version 2>/dev/null | head -n1 | awk '{print $NF}')
        # Remove any leading 'v'
        current_ctk_version=${current_ctk_version#v}
        # Extract the major.minor portion (e.g. "1.17")
        current_major_minor=$(echo "$current_ctk_version" | cut -d. -f1,2)
        
        if [[ "$(echo -e "$required_ctk_version\n$current_major_minor" | sort -V | head -n1)" != "$required_ctk_version" ]]; then
            echo_info "nvidia-ctk version ($current_ctk_version) is older than required ($required_ctk_version)."
            nvidia_ctk_needs_install=true
        else
            echo_info "nvidia-ctk version ($current_ctk_version) meets the requirement (>= $required_ctk_version)."
        fi
    else
        echo_info "nvidia-ctk not found."
        nvidia_ctk_needs_install=true
    fi

    if $nvidia_ctk_needs_install; then
        echo_info "Installing/upgrading nvidia-container-toolkit..."
        sudo rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
        && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        sudo apt update
        sudo apt install nvidia-container-toolkit nvidia-container-toolkit-base -y --allow-change-held-packages
    fi

    if command -v docker &> /dev/null; then
        echo_info "Docker is installed."
        # Check if Docker is managed by systemd
        if sudo systemctl list-units --full -all | grep -q 'docker.service'; then
            echo_info "Docker is managed by systemd. Attempting to restart Docker service..."

            # Restart Docker service
            sudo systemctl restart docker.service

            if [ $? -eq 0 ]; then
                echo_info "Docker service restarted successfully."
            else
                echo_info "Failed to restart Docker service. Attempting a stop & start"
                sudo systemctl stop docker.service
                sleep 3
                sudo systemctl start docker.service
            fi
        else
            echo_info "Docker is not managed by systemd or the docker.service does not exist."
        fi
    else
        echo_info "Docker is not installed."
    fi
}

install_docker() {
    if ! command -v docker &> /dev/null; then
        echo_info "Installing Docker..."
        # https://docs.docker.com/engine/install/ubuntu/
        with_retry 5 10s sudo apt-get update
        sudo apt-get install -y \
            ca-certificates \
            curl \
            gnupg \
            lsb-release
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        with_retry 5 10s sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        # https://docs.docker.com/engine/install/linux-postinstall/
        sudo systemctl enable docker.service
        sudo systemctl enable containerd.service
        
        if ! sudo systemctl start docker; then
            echo_info "Failed to start Docker service. Exiting."
        fi
        echo_info "Docker installed successfully."
    else
        echo_info "Docker is already installed."
    fi

    echo_info "Configuring Docker daemon MTU..."
    HOST_MTU=$(ip -o link show $(ip route get 8.8.8.8 | grep -oP 'dev \K\w+') | grep -oP 'mtu \K\d+')
    if [ -n "$HOST_MTU" ]; then
        echo_info "Host MTU detected: $HOST_MTU"
        sudo mkdir -p /etc/docker
        if [ -s /etc/docker/daemon.json ]; then
            # If daemon.json exists, merge in the MTU setting
            if jq . /etc/docker/daemon.json > /dev/null 2>&1; then
                # Valid JSON file, update it
                echo_info "Valid JSON file, updating /etc/docker/daemon.json"
                # Create a temporary file for the updated JSON
                TEMP_FILE=$(mktemp)

                # Update the JSON and save to temp file
                sudo jq --arg mtu "$HOST_MTU" '. + {"mtu": ($mtu|tonumber)}' /etc/docker/daemon.json > "$TEMP_FILE"

                # Verify the temp file has content
                if [ -s "$TEMP_FILE" ]; then
                    # Replace the original file with the updated one
                    sudo cp "$TEMP_FILE" /etc/docker/daemon.json
                else
                    echo_info "Error updating daemon.json with MTU setting"
                fi

                # Clean up
                rm -f "$TEMP_FILE"
            else
                # Invalid JSON, overwrite it
                echo_info "Invalid JSON, overwriting /etc/docker/daemon.json"
                echo "{\"mtu\": $HOST_MTU}" | sudo tee /etc/docker/daemon.json > /dev/null
            fi
        else
            # If daemon.json doesn't exist, create it
            echo "{\"mtu\": $HOST_MTU}" | sudo tee /etc/docker/daemon.json > /dev/null
        fi
        sudo systemctl restart docker
        echo_info "Docker MTU configured to match host MTU"
    else
        echo_info "Could not detect host MTU, skipping Docker MTU configuration"
    fi

    echo_info "Configuring cdi"
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml || echo_info "issue enabling CDI"

    echo_info "Configuring NVIDIA runtime and restarting Docker..."
    if ! sudo nvidia-ctk runtime configure --runtime=docker --set-as-default; then
        echo_info "Failed to configure NVIDIA runtime. Skipping Docker restart."
    else
        if ! sudo systemctl restart docker.service; then
            echo_info "Failed to restart Docker service. Attempting to start it..."
            if ! sudo systemctl start docker.service; then
                echo_info "Failed to start Docker service. Please check your Docker installation."
            else
                echo_info "Failed to restart Docker service. Attempting a stop & start"
                sudo systemctl stop docker.service
                sleep 3
                sudo systemctl start docker.service 
            fi
        fi
        echo_info "NVIDIA runtime configured and Docker service restarted successfully."
    fi

    echo_info "Setting NVIDIA CTK default mode to 'cdi'..."
    sudo nvidia-ctk config --in-place --set nvidia-container-runtime.mode=cdi || echo_info "Failed to set NVIDIA CTK default mode to 'cdi'."

    # Establish service for cdi refresh
    SERVICE_FILE="/etc/systemd/system/nvidia-cdi-refresh.service"
    if [ ! -f "$SERVICE_FILE" ]; then
    sudo tee "$SERVICE_FILE" >/dev/null << 'EOF'
[Unit]
Description=Refresh NVIDIA CDI configuration and restart Docker
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
ExecStartPost=/bin/systemctl restart docker.service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload && sudo systemctl enable --now nvidia-cdi-refresh.service
    echo_info "nvidia-cdi-refresh service configured."
    else
    echo_info "nvidia-cdi-refresh service already exists."
    fi

    # Verify Docker is running
    if ! docker info &>/dev/null; then
        echo_info "Docker is not running. Please check your Docker installation."
    else
        echo_info "Docker is running correctly."
        docker --version
    fi

    # add user to docker group
    echo_info "Adding user $INST_USER to docker group..."
    sudo usermod -aG docker $INST_USER
}

init_ephemeral_dir() {
    echo_info "Creating ephemeral directory..."
    sudo mkdir -p /ephemeral
    sudo chmod 777 /ephemeral
}

init_workbench_install() {
    echo_info "Setting up workbench installation for user $INST_USER..."
    echo_info "User home directory: $user_home"
    
    # Create the directory structure
    sudo -u $INST_USER mkdir -p $user_home/.nvwb/bin
    
    # Create the install script with heredoc that preserves variable expansion
    sudo -u $INST_USER bash -c "cat > $user_home/.nvwb/install.sh << 'EOFMARKER'
#!/bin/bash
exec >> \$HOME/.nvwb/install.log 2>&1
echo \"Starting NVIDIA AI Workbench installation...\"
curl -L https://workbench.download.nvidia.com/stable/workbench-cli/\$(curl -L -s https://workbench.download.nvidia.com/stable/workbench-cli/LATEST)/nvwb-cli-\$(uname)-\$(uname -m) --output \$HOME/.nvwb/bin/nvwb-cli
chmod +x \$HOME/.nvwb/bin/nvwb-cli
sudo -E \$HOME/.nvwb/bin/nvwb-cli install --uid 1000 --gid 1000 --accept --noninteractive --drivers --docker -o json
echo \"NVIDIA AI Workbench installation completed successfully\"
EOFMARKER"
    
    # Set proper permissions and run in background exactly like original
    sudo -u $INST_USER bash -c "chmod +x $user_home/.nvwb/install.sh && (nohup $user_home/.nvwb/install.sh > /dev/null 2>&1 &)"
    
    echo_info "Workbench installation initiated in the background."
}

wait_docker() {
    MAX_RETRIES=5
    RETRY_INTERVAL=5
    for i in $(seq 1 $MAX_RETRIES); do
        if sudo docker info &>/dev/null; then
            echo_info "Docker daemon is up and running"
            return 0
        fi
        
        if [ $i -eq $MAX_RETRIES ]; then
            echo_info "Error: Docker daemon failed to start properly after $MAX_RETRIES attempts"
            return 1
        fi
        
        echo_info "Waiting for Docker daemon to start (attempt $i/$MAX_RETRIES)..."
        sleep $RETRY_INTERVAL
    done
}

# Function to check image prestaging status and import images if ready
check_and_import_images() {
    echo_info "Checking Docker image prestaging status..."
    
    # Check if status file exists
    if [ ! -f "$PRESTAGE_STATUS_FILE" ]; then
        echo_info "Image prestaging status file not found. Prestaging may not be configured."
        return 0
    fi
    
    # Check if jq is installed
    if ! command -v jq &>/dev/null; then
        echo_info "jq is not installed. Installing..."
        sudo apt-get update -y > /dev/null
        sudo apt-get install -y jq > /dev/null
    fi
    
    # Check status
    local status=$(jq -r '.status' "$PRESTAGE_STATUS_FILE" 2>/dev/null || echo "unknown")
    local total=$(jq -r '.total' "$PRESTAGE_STATUS_FILE" 2>/dev/null || echo "0")
    local completed=$(jq -r '.completed' "$PRESTAGE_STATUS_FILE" 2>/dev/null || echo "0")
    
    echo_info "Image prestaging status: $status ($completed/$total completed)"
    
    # If prestaging is completed, import the images
    if [ "$status" = "completed" ] || [ "$status" = "completed_with_errors" ]; then
        echo_info "Image prestaging completed. Importing images..."
        
        # Check if import script exists
        if [ ! -f "$IMPORT_SCRIPT" ]; then
            echo_info "Image import script not found: $IMPORT_SCRIPT"
            return 1
        fi
        
        # Run the import script
        sudo "$IMPORT_SCRIPT" "$INST_USER" "$PRESTAGE_STATUS_FILE" "$PRESTAGE_DIR"
        
        if [ $? -eq 0 ]; then
            echo_info "Docker images imported successfully"
        else
            echo_info "Some Docker images failed to import. Check logs for details."
        fi
    else
        echo_info "Image prestaging is not yet complete. Current status: $status"
        echo_info "Images will be available after prestaging completes."
    fi
    
    return 0
}

# Function to monitor image prestaging status with timeout
monitor_image_prestaging() {
    local timeout=300  # 5 minutes timeout
    local check_interval=15
    local elapsed=0
    
    echo_info "Monitoring image prestaging status (timeout: ${timeout}s)..."
    
    # Check if status file exists
    if [ ! -f "$PRESTAGE_STATUS_FILE" ]; then
        echo_info "Image prestaging status file not found. Skipping monitoring."
        return 0
    fi
    
    # Check if jq is installed
    if ! command -v jq &>/dev/null; then
        echo_info "jq is not installed. Installing..."
        sudo apt-get update -y > /dev/null
        sudo apt-get install -y jq > /dev/null
    fi
    
    while [ $elapsed -lt $timeout ]; do
        # Check status
        local status=$(jq -r '.status' "$PRESTAGE_STATUS_FILE" 2>/dev/null || echo "unknown")
        local total=$(jq -r '.total' "$PRESTAGE_STATUS_FILE" 2>/dev/null || echo "0")
        local completed=$(jq -r '.completed' "$PRESTAGE_STATUS_FILE" 2>/dev/null || echo "0")
        
        echo_info "Image prestaging status: $status ($completed/$total completed)"
        
        # If prestaging is completed, import the images
        if [ "$status" = "completed" ] || [ "$status" = "completed_with_errors" ]; then
            echo_info "Image prestaging completed. Importing images..."
            check_and_import_images
            return 0
        fi
        
        # If still initializing or downloading, wait and check again
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
    
    echo_info "Timeout reached while waiting for image prestaging to complete."
    echo_info "Images will be available after prestaging completes in the background."
    return 0
}

# Initialize log file at script start
init_log_file

# Run functions with error handling to prevent script from continuing if a critical function fails
echo_info "Starting system configuration..."
update_dns || { echo_info "DNS configuration failed"; exit 1; }
disable_unattended_upgrades || { echo_info "Disabling unattended upgrades failed"; exit 1; }
install_docker || { echo_info "Docker installation failed"; exit 1; }
install_nvidia_driver || { echo_info "NVIDIA driver installation failed"; exit 1; }
install_metrics || { echo_info "Metrics installation failed"; exit 1; }
init_ephemeral_dir || { echo_info "Ephemeral directory creation failed"; exit 1; }

# These are non-critical, so we can continue even if they fail
init_workbench_install || echo_info "Workbench installation setup failed, but continuing"
wait_docker || echo_info "Docker daemon not responding, but continuing"

# Check image prestaging status and import images if ready
check_and_import_images || echo_info "Image import check failed, but continuing"

echo_info "System configuration completed successfully"

# Monitor image prestaging status in the background
(monitor_image_prestaging &)
