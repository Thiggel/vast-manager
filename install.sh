#!/usr/bin/env bash

# install.sh - Install the vast-manager script

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEFAULT_INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.vast-manager"
USER_INSTALL_DIR="$HOME/bin"

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

# Determine installation directory
if [ -w "$DEFAULT_INSTALL_DIR" ]; then
    # User has write permission to /usr/local/bin
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
else
    # User doesn't have permission, fall back to ~/bin
    echo "Notice: You don't have write permission to $DEFAULT_INSTALL_DIR"
    echo "Installing to $USER_INSTALL_DIR instead."
    
    # Create user bin directory if it doesn't exist
    mkdir -p "$USER_INSTALL_DIR"
    
    # Add to PATH if not already there
    if [[ ":$PATH:" != *":$USER_INSTALL_DIR:"* ]]; then
        echo "Adding $USER_INSTALL_DIR to your PATH in ~/.bashrc and ~/.zshrc"
        
        # Add to .bashrc if it exists
        if [ -f "$HOME/.bashrc" ]; then
            echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
        fi
        
        # Add to .zshrc if it exists (common on macOS)
        if [ -f "$HOME/.zshrc" ]; then
            echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zshrc"
        fi
        
        echo "Note: You'll need to restart your terminal or run 'source ~/.bashrc' (or source ~/.zshrc) for this to take effect"
    fi
    
    INSTALL_DIR="$USER_INSTALL_DIR"
fi

# Copy the script to the install directory
echo "Installing vast-manager.sh to $INSTALL_DIR..."
cp "$SCRIPT_DIR/vast-manager.sh" "$INSTALL_DIR/vast-manager.sh"
chmod +x "$INSTALL_DIR/vast-manager.sh"

# Create symlink with shorter name
ln -sf "$INSTALL_DIR/vast-manager.sh" "$INSTALL_DIR/vast-manager" || true

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

if [ "$INSTALL_DIR" = "$USER_INSTALL_DIR" ]; then
    if [[ ":$PATH:" != *":$USER_INSTALL_DIR:"* ]]; then
        echo ""
        echo "IMPORTANT: You need to restart your terminal or run one of these commands to use vast-manager immediately:"
        echo "  source ~/.bashrc   # if you use bash"
        echo "  source ~/.zshrc    # if you use zsh (default on modern macOS)"
    fi
fi

echo ""
echo "Alternatively, you can run the script directly with:"
echo "$INSTALL_DIR/vast-manager.sh"
