#!/usr/bin/env bash

# install.sh - Install the vast-manager script

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.vast-manager"

# Check if vast-cli is installed
if ! command -v vastai > /dev/null; then
    echo "Error: vast-cli is not installed."
    echo "Please install the Vast.ai CLI first with: pip install vast-ai"
    echo "For more information, visit: https://cloud.vast.ai/cli/"
    exit 1
fi

# Check for Python3
if ! command -v python3 > /dev/null; then
    echo "Error: Python 3 is required but not installed."
    echo "Please install Python 3 before continuing."
    exit 1
fi

# Create the config directory
mkdir -p "$CONFIG_DIR"

# Copy the script to the install directory
echo "Installing vast-manager.sh to $INSTALL_DIR..."
cp "$SCRIPT_DIR/vast-manager.sh" "$INSTALL_DIR/vast-manager.sh"
chmod +x "$INSTALL_DIR/vast-manager.sh"

# Create symlink with shorter name
ln -sf "$INSTALL_DIR/vast-manager.sh" "$INSTALL_DIR/vast-manager"

# Create empty instance tracking file
touch "$CONFIG_DIR/instances.json"
echo "[]" > "$CONFIG_DIR/instances.json"

# Create log file
touch "$CONFIG_DIR/vast-manager.log"

echo "Installation complete!"
echo "Usage: vast-manager create [gpu_type] [template_name] [time_limit_hours]"
echo "       vast-manager status"
echo "       vast-manager extend [instance_id] [additional_hours]"
echo "       vast-manager destroy [instance_id]"
echo ""
echo "Example: vast-manager create RTX4090 my-template 3"
