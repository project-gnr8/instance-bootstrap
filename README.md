# instance-bootstrap


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