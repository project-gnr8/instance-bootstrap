# instance-bootstrap


## Bootstrapping Example

```bash
# Ad hoc scripts
BRANCH=feat-docker-prestage
curl -sSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/project-gnr8/instance-bootstrap/refs/heads/${BRANCH}/oneshot.sh | bash -s -- ubuntu 535 "aws_timestream_access_key='test_key' aws_timestream_secret_key='test_secret' aws_timestream_database='test_db' aws_timestream_region='test_region' environmentID='test_envid'" '["nvcr.io/nvidia/rapidsai/notebooks:24.12-cuda12.5-py3.12"]' 'brev-image-prestage' ${BRANCH}

# Ad hoc scripts
INST_USER=jmorgan
GCS_BUCKET=brev-image-prestage
IMAGE_LIST_JSON='["nvcr.io/nvidia/rapidsai/notebooks:24.12-cuda12.5-py3.12"]'

/opt/instance-bootstrap/image-prestage.sh ${INST_USER} ${IMAGE_LIST_JSON} ${GCS_BUCKET}
/opt/instance-bootstrap/image-import.sh ${INST_USER} /opt/prestage/docker-images-prestage-status.json /opt/prestage/docker-images

```

## Resource Cleanup

```bash
# Stop and disable services
sudo systemctl stop instance-oneshot.service workbench-install.service
sudo systemctl disable instance-oneshot.service workbench-install.service
sudo systemctl stop docker-image-prestage.service
sudo systemctl disable docker-image-prestage.service


# Remove service files
sudo rm -f /etc/systemd/system/instance-oneshot.service
sudo rm -f /etc/systemd/system/workbench-install.service
sudo rm -f /etc/systemd/system/docker-image-prestage.service

# Remove installed scripts
sudo rm -f /opt/startup.sh
sudo rm -f $HOME/.nvwb/install.sh
sudo rm -rf $HOME/.nvwb/*

# Remove prestaging files
sudo rm -rf /opt/prestage

# Clear journal logs
sudo journalctl --rotate
sudo journalctl --vacuum-time=1s

# Remove log files
sudo rm -f /var/log/instance-bootstrap/oneshot.log
sudo rm -f /var/log/instance-bootstrap/startup.log

# Reload systemd
sudo systemctl daemon-reload
sudo systemctl reset-failed

# Kill any remaining processes
sudo pkill -f 'startup.sh'
sudo pkill -f 'nvwb-cli'
```

## Troubleshooting Docker Image Prestaging Service

If you encounter issues with the Docker image prestaging service, follow these troubleshooting steps:

### 1. Check Service Status

```bash
# Check if the service is active
sudo systemctl status docker-image-prestage.service

# View detailed service properties
sudo systemctl show docker-image-prestage.service

# Check if the service is enabled
sudo systemctl is-enabled docker-image-prestage.service
```

### 2. Review Service Logs

```bash
# View all logs for the service
sudo journalctl -u docker-image-prestage.service

# View only the most recent logs
sudo journalctl -u docker-image-prestage.service -n 50

# Follow logs in real-time
sudo journalctl -u docker-image-prestage.service -f
```

### 3. Check Environment Configuration

```bash
# Verify environment file exists and has correct permissions
ls -la /etc/systemd/docker-image-prestage.env

# Check environment file contents
sudo cat /etc/systemd/docker-image-prestage.env

# Verify the IMAGE_LIST_JSON format is correct (should be properly quoted)
```

### 4. Check Status File

```bash
# View the current status file
cat /opt/prestage/docker-images-prestage-status.json

# If status is stuck at "downloading", manually update it (replace values as needed)
echo '{"status":"completed","completed":1,"total":1,"images":["nvcr.io/nvidia/rapidsai/notebooks:24.12-cuda12.5-py3.12"]}' | sudo tee /opt/prestage/docker-images-prestage-status.json
```

### 5. Verify Script Permissions and Execution

```bash
# Check if scripts are executable
ls -la /opt/instance-bootstrap/image-prestage.sh
ls -la /opt/instance-bootstrap/image-import.sh

# Make scripts executable if needed
sudo chmod +x /opt/instance-bootstrap/image-prestage.sh
sudo chmod +x /opt/instance-bootstrap/image-import.sh

# Run the prestage script manually for testing
sudo /opt/instance-bootstrap/image-prestage.sh ubuntu '["nvcr.io/nvidia/rapidsai/notebooks:24.12-cuda12.5-py3.12"]' brev-image-prestage
```

### 6. Check for Directory and Permission Issues

```bash
# Verify prestage directories exist with correct permissions
ls -la /opt/prestage/
ls -la /opt/prestage/docker-images/

# Create directories if missing
sudo mkdir -p /opt/prestage/docker-images
sudo chmod 775 /opt/prestage /opt/prestage/docker-images
sudo chown ubuntu:ubuntu /opt/prestage /opt/prestage/docker-images
```

### 7. Restart the Service

```bash
# Reload systemd configuration
sudo systemctl daemon-reload

# Restart the service
sudo systemctl restart docker-image-prestage.service
```

### 8. Common Issues and Solutions

1. **Service inactive despite being enabled**
   - Check for syntax errors in the service file
   - Verify the ExecStart path is correct
   - Ensure all required directories exist

2. **Status file stuck at "downloading"**
   - The script may have terminated prematurely
   - Check for errors in the logs
   - Manually update the status file if needed

3. **Permission denied errors**
   - Ensure scripts are executable
   - Check ownership of directories and files
   - Verify the service is running as the correct user

4. **Network-related failures**
   - Verify connectivity to the GCS signed URL service
   - Check if the GCS bucket exists and is accessible
   - Ensure Docker service is running properly

5. **JSON parsing errors**
   - Verify the IMAGE_LIST_JSON format in the environment file
   - Ensure proper quoting of the JSON string
   - Check for syntax errors in the JSON
