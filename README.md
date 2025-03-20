# instance-bootstrap


## Bootstrapping Example

```bash
curl -sSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/project-gnr8/instance-bootstrap/refs/heads/feat-docker-prestage/oneshot.sh | bash -s -- ubuntu 535 "aws_timestream_access_key='test_key' aws_timestream_secret_key='test_secret' aws_timestream_database='test_db' aws_timestream_region='test_region' environmentID='test_envid'" '["nvcr.io/nvidia/rapidsai/notebooks:24.12-cuda12.5-py3.12"]' 'brev-image-prestage' 'feat-docker-prestage'


```

## Resource Cleanup

```bash
# Stop and disable services
sudo systemctl stop instance-oneshot.service workbench-install.service
sudo systemctl disable instance-oneshot.service workbench-install.service

# Remove service files
sudo rm -f /etc/systemd/system/instance-oneshot.service
sudo rm -f /etc/systemd/system/workbench-install.service

# Remove installed scripts
sudo rm -f /opt/startup.sh
sudo rm -f $HOME/.nvwb/install.sh
sudo rm -rf $HOME/.nvwb/*

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
