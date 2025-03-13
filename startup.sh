#!/bin/bash

# Strict mode to catch errors and prevent forking issues
set -euo pipefail

INST_USER=$1
INST_DRIVER=$2
INST_METRICS_VARS="$3"

# Define log file path (can be overridden before sourcing)
user_home=$(eval echo ~$INST_USER)
LOG_FILE=${LOG_FILE:-"$user_home/.verb-setup.log"}
PRIMARY_DNS="1.1.1.1"
BACKUP_DNS="8.8.8.8"

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
echo() {
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    # Format for console (with colors)
    printf "\033[1;34m[INFO]\033[0m [%s] %s\n" "$timestamp" "$1" >&1
    # Format for log file (without colors)
    printf "[%s] [INFO] %s\n" "$timestamp" "$1" >> "$LOG_FILE"
}

# Function to wait for apt lock to be free
wait_for_apt_lock() {
    local lock_file="/var/lib/dpkg/lock-frontend"
    local lock_wait_time=360  # Maximum wait time in seconds
    local interval=5          # Interval between checks in seconds
    local elapsed=0

    echo "Waiting for apt lock to be released..."

    while sudo fuser "$lock_file" >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$lock_wait_time" ]; then
            echo "Timeout waiting for apt lock to be released."
            return 1
        fi
        echo "Apt lock is currently held by another process. Waiting..."
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    return 0
}

disable_unattended_upgrades() {
    echo "Disabling unattended-upgrades..."
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
    echo "Updating DNS configuration..."
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

    echo "DNS servers have been updated to ${PRIMARY_DNS} (primary) and ${BACKUP_DNS} (backup)."
}

install_metrics() {
    echo "Setting up metrics with variables: $INST_METRICS_VARS"
    
    # The metrics script expects individual space-separated arguments
    # We need to pass them directly to bash -s without any array processing
    curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | \
        bash -s -- $INST_METRICS_VARS
    
    echo "Metrics setup completed"
}

install_nvidia_driver() {
    if [ "$INST_DRIVER" = "disabled" ]; then
        echo "NVIDIA driver installation is disabled. Skipping..."
        return
    else
        echo "Installing NVIDIA driver..."
        desired_version=%s
        # Attempt to get the currently used NVIDIA driver version
        current_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null) || current_version=""

        # Check if nvidia-smi command succeeded
        if [ -z "$current_version" ]; then
            echo "nvidia-smi command failed. This could indicate that NVIDIA drivers are not installed."
            echo "Proceeding with installation of nvidia-driver-$desired_version..."
            sudo apt update
            sudo apt install "nvidia-driver-$desired_version" -y
        else
            # Extract major version numbers for comparison
            current_major=$(echo $current_version | cut -d. -f1)
            desired_major=$(echo $desired_version | cut -d. -f1)
            
            # Compare versions
            if [ "$current_major" -lt "$desired_major" ]; then
                echo "Current NVIDIA driver version ($current_version) is older than $desired_version. Installing $desired_version..."
                sudo apt update
                sudo apt install "nvidia-driver-$desired_version" -y
            else
                echo "Current NVIDIA driver version ($current_version) is greater than or equal to $desired_version. Keeping the current version."
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
            echo "nvidia-ctk version ($current_ctk_version) is older than required ($required_ctk_version)."
            nvidia_ctk_needs_install=true
        else
            echo "nvidia-ctk version ($current_ctk_version) meets the requirement (>= $required_ctk_version)."
        fi
    else
        echo "nvidia-ctk not found."
        nvidia_ctk_needs_install=true
    fi

    if $nvidia_ctk_needs_install; then
        echo "Installing/upgrading nvidia-container-toolkit..."
        sudo rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
        && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        sudo apt update
        sudo apt install nvidia-container-toolkit nvidia-container-toolkit-base -y --allow-change-held-packages
    fi

    if command -v sudo docker &> /dev/null; then
        echo "Docker is installed."
        # Check if Docker is managed by systemd
        if sudo systemctl list-units --full -all | grep -q 'docker.service'; then
            echo "Docker is managed by systemd. Attempting to restart Docker service..."

            # Restart Docker service
            sudo systemctl restart docker.service

            if [ $? -eq 0 ]; then
                echo "Docker service restarted successfully."
            else
                echo "Failed to restart Docker service."
            fi
        else
            echo "Docker is not managed by systemd or the docker.service does not exist."
        fi
    else
        echo "Docker is not installed."
    fi
}

install_docker() {
    if ! type docker &> /dev/null; then
        echo "Installing Docker..."
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
            echo "Failed to start Docker service. Exiting."
        fi
        echo "Docker installed successfully."
    else
        echo "Docker is already installed."
    fi

    echo "Configuring Docker daemon MTU..."
    HOST_MTU=$(ip -o link show $(ip route get 8.8.8.8 | grep -oP 'dev \K\w+') | grep -oP 'mtu \K\d+')
    if [ -n "$HOST_MTU" ]; then
        echo "Host MTU detected: $HOST_MTU"
        sudo mkdir -p /etc/docker
        if [ -s /etc/docker/daemon.json ]; then
            # If daemon.json exists, merge in the MTU setting
            if jq . /etc/docker/daemon.json > /dev/null 2>&1; then
                # Valid JSON file, update it
                echo "Valid JSON file, updating /etc/docker/daemon.json"
                # Create a temporary file for the updated JSON
                TEMP_FILE=$(mktemp)

                # Update the JSON and save to temp file
                sudo jq --arg mtu "$HOST_MTU" '. + {"mtu": ($mtu|tonumber)}' /etc/docker/daemon.json > "$TEMP_FILE"

                # Verify the temp file has content
                if [ -s "$TEMP_FILE" ]; then
                    # Replace the original file with the updated one
                    sudo cp "$TEMP_FILE" /etc/docker/daemon.json
                else
                    echo "Error updating daemon.json with MTU setting"
                fi

                # Clean up
                rm -f "$TEMP_FILE"
            else
                # Invalid JSON, overwrite it
                echo "Invalid JSON, overwriting /etc/docker/daemon.json"
                echo "{\"mtu\": $HOST_MTU}" | sudo tee /etc/docker/daemon.json > /dev/null
            fi
        else
            # If daemon.json doesn't exist, create it
            echo "{\"mtu\": $HOST_MTU}" | sudo tee /etc/docker/daemon.json > /dev/null
        fi
        sudo systemctl restart docker
        echo "Docker MTU configured to match host MTU"
    else
        echo "Could not detect host MTU, skipping Docker MTU configuration"
    fi

    echo "Configuring cdi"
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml || echo "issue enabling CDI"

    echo "Configuring NVIDIA runtime and restarting Docker..."
    if ! sudo nvidia-ctk runtime configure --runtime=docker --set-as-default; then
        echo "Failed to configure NVIDIA runtime. Skipping Docker restart."
    else
        if ! sudo systemctl restart docker.service; then
            echo "Failed to restart Docker service. Attempting to start it..."
            if ! sudo systemctl start docker.service; then
                echo "Failed to start Docker service. Please check your Docker installation."
            fi
        fi
        echo "NVIDIA runtime configured and Docker service restarted successfully."
    fi

    echo "Setting NVIDIA CTK default mode to 'cdi'..."
    sudo nvidia-ctk config --in-place --set nvidia-container-runtime.mode=cdi || echo "Failed to set NVIDIA CTK default mode to 'cdi'."

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
    echo "nvidia-cdi-refresh service configured."
    else
    echo "nvidia-cdi-refresh service already exists."
    fi

    # Verify Docker is running
    if ! docker info &>/dev/null; then
        echo "Docker is not running. Please check your Docker installation."
    else
        echo "Docker is running correctly."
        docker --version
    fi

    # add user to docker group
    echo "Adding user $INST_USER to docker group..."
    sudo usermod -aG docker $INST_USER
}

init_ephemeral_dir() {
    echo "Creating ephemeral directory..."
    sudo mkdir -p /ephemeral
    sudo chmod 777 /ephemeral
}

init_workbench_install() {
    echo "Setting up workbench installation for user $INST_USER..."
    echo "User home directory: $user_home"
    
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
    
    echo "Workbench installation initiated in the background."
}

wait_docker() {
    MAX_RETRIES=5
    RETRY_INTERVAL=5
    for i in $(seq 1 $MAX_RETRIES); do
        if sudo docker info &>/dev/null; then
            echo "Docker daemon is up and running"
            return 0
        fi
        
        if [ $i -eq $MAX_RETRIES ]; then
            echo "Error: Docker daemon failed to start properly after $MAX_RETRIES attempts"
            return 1
        fi
        
        echo "Waiting for Docker daemon to start (attempt $i/$MAX_RETRIES)..."
        sleep $RETRY_INTERVAL
    done
}

# Initialize log file at script start
init_log_file

# Run functions with error handling to prevent script from continuing if a critical function fails
echo "Starting system configuration..."
update_dns || { echo "DNS configuration failed"; exit 1; }
disable_unattended_upgrades || { echo "Disabling unattended upgrades failed"; exit 1; }
install_nvidia_driver || { echo "NVIDIA driver installation failed"; exit 1; }
install_docker || { echo "Docker installation failed"; exit 1; }
install_metrics || { echo "Metrics installation failed"; exit 1; }
init_ephemeral_dir || { echo "Ephemeral directory creation failed"; exit 1; }

# These are non-critical, so we can continue even if they fail
init_workbench_install || echo "Workbench installation setup failed, but continuing"
wait_docker || echo "Docker daemon not responding, but continuing"

echo "System configuration completed successfully"
