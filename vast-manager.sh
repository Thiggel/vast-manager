#!/usr/bin/env bash

# vast-manager.sh - A script to manage Vast.ai instances
# Usage: vast-manager.sh [command] [options]
#   Commands:
#     create [gpu_type] [template_name] [time_limit_hours]
#     status
#     extend [instance_id] [additional_hours]
#     destroy [instance_id]

set -e

# Configuration
VAST_CONFIG_DIR="$HOME/.vast-manager"
INSTANCES_FILE="$VAST_CONFIG_DIR/instances.json"
LOG_FILE="$VAST_CONFIG_DIR/vast-manager.log"

# Ensure config directory exists
mkdir -p "$VAST_CONFIG_DIR"
touch "$INSTANCES_FILE"
touch "$LOG_FILE"

# Logging function
log() {
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $1" >> "$LOG_FILE"
    echo "$1"
}

# Check if vast-cli is installed
if ! command -v vast > /dev/null; then
    log "Error: vast-cli is not installed. Please install it first."
    exit 1
fi

# Create a new instance
create_instance() {
    local gpu_type="$1"
    local template_name="$2"
    local time_limit_hours="$3"
    
    if [[ -z "$gpu_type" || -z "$template_name" || -z "$time_limit_hours" ]]; then
        log "Error: Missing required parameters."
        log "Usage: vast-manager.sh create [gpu_type] [template_name] [time_limit_hours]"
        exit 1
    fi
    
    # Convert time limit to timestamp
    local end_time=$(date -v+${time_limit_hours}H +%s)
    
    log "Searching for cheapest $gpu_type instance..."
    
    # Find the cheapest instance with the requested GPU
    local offers_json=$(vast search offers --raw -o 'gpu_name[]="$gpu_type"' 2>/dev/null)
    
    if [[ -z "$offers_json" || "$offers_json" == "[]" ]]; then
        log "Error: No instances found with GPU type: $gpu_type"
        exit 1
    fi
    
    # Parse the cheapest offer ID using Python (more reliable than jq for this purpose)
    local cheapest_offer_id=$(python3 -c "
import json, sys
offers = json.loads('$offers_json')
if not offers:
    sys.exit(1)
# Sort by dph_total (dollars per hour)
offers.sort(key=lambda x: float(x.get('dph_total', float('inf'))))
print(offers[0]['id'])
")
    
    if [[ -z "$cheapest_offer_id" ]]; then
        log "Error: Failed to find a suitable offer."
        exit 1
    fi
    
    log "Found cheapest offer with ID: $cheapest_offer_id"
    
    # Create the instance with the specified template
    log "Creating instance with template: $template_name"
    local create_result=$(vast create instance $cheapest_offer_id --image "$template_name" --raw 2>/dev/null)
    
    # Extract instance ID and SSH command
    local instance_id=$(echo "$create_result" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print(data.get('id', ''))
except:
    print('')
")
    
    if [[ -z "$instance_id" ]]; then
        log "Error: Failed to create instance."
        exit 1
    fi
    
    log "Created instance with ID: $instance_id"
    
    # Get instance details including SSH command
    local instance_json=$(vast show instances $instance_id --raw 2>/dev/null)
    local ssh_command=$(echo "$instance_json" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if data and len(data) > 0:
        print(data[0].get('ssh_command', ''))
    else:
        print('')
except:
    print('')
")
    
    if [[ -z "$ssh_command" ]]; then
        log "Error: Failed to get SSH command for instance $instance_id"
        log "The instance has been created, but you'll need to connect manually."
        exit 1
    fi
    
    # Store instance info
    echo "$instance_json" | python3 -c "
import json, sys, os
try:
    new_instance = json.loads(sys.stdin.read())[0]
    instances_file = '$INSTANCES_FILE'
    
    # Read existing instances
    if os.path.exists(instances_file) and os.path.getsize(instances_file) > 0:
        with open(instances_file, 'r') as f:
            instances = json.load(f)
    else:
        instances = []
    
    # Add new instance with time limit
    new_instance['end_time'] = $end_time
    new_instance['created_at'] = $(date +%s)
    instances.append(new_instance)
    
    # Write updated instances
    with open(instances_file, 'w') as f:
        json.dump(instances, f, indent=2)
except Exception as e:
    print(f'Error updating instances file: {e}', file=sys.stderr)
"
    
    # Launch timer process in background
    nohup bash -c "
        sleep $((time_limit_hours * 3600))
        \"$0\" destroy $instance_id auto
    " > /dev/null 2>&1 &
    
    # Register with launchd for macOS to ensure it runs even in sleep mode
    cat > "$VAST_CONFIG_DIR/com.vastmanager.instance.$instance_id.plist" << EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.vastmanager.instance.$instance_id</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which bash)</string>
        <string>-c</string>
        <string>$(which bash) $(realpath "$0") destroy $instance_id auto</string>
    </array>
    <key>StartInterval</key>
    <integer>$((time_limit_hours * 3600))</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOL
    
    launchctl load "$VAST_CONFIG_DIR/com.vastmanager.instance.$instance_id.plist"
    
    log "Instance will be automatically destroyed after $time_limit_hours hours."
    log "Connecting to instance..."
    
    # Execute SSH command
    eval "$ssh_command"
    
    # After SSH disconnects, ask if user wants to destroy the instance
    read -p "SSH connection closed. Do you want to destroy the instance now? (y/n): " destroy_now
    if [[ "$destroy_now" == "y" || "$destroy_now" == "Y" ]]; then
        destroy_instance "$instance_id"
    else
        log "Instance $instance_id is still running. Use 'vast-manager.sh destroy $instance_id' to destroy it manually."
    fi
}

# Show status of running instances
show_status() {
    if [[ ! -f "$INSTANCES_FILE" || ! -s "$INSTANCES_FILE" ]]; then
        log "No instances found."
        return
    fi
    
    python3 -c "
import json, sys, time
from datetime import datetime, timedelta

try:
    with open('$INSTANCES_FILE', 'r') as f:
        instances = json.load(f)
    
    if not instances:
        print('No instances found.')
        sys.exit(0)
    
    print(f\"{'ID':<10} {'GPU':<15} {'Status':<10} {'Time Remaining':<20} {'Cost':<10}\")
    print('-' * 70)
    
    current_time = int(time.time())
    
    for instance in instances:
        id = instance.get('id', 'N/A')
        gpu = instance.get('gpu_name', 'N/A')
        status = instance.get('actual_status', 'unknown')
        
        end_time = instance.get('end_time', 0)
        remaining_seconds = max(0, end_time - current_time)
        remaining_time = str(timedelta(seconds=remaining_seconds))
        
        if remaining_seconds <= 0:
            time_str = 'EXPIRED'
        else:
            time_str = remaining_time
        
        dph = float(instance.get('dph_total', 0))
        running_hours = (current_time - instance.get('created_at', current_time)) / 3600
        cost = f'${dph * running_hours:.2f}'
        
        print(f\"{id:<10} {gpu:<15} {status:<10} {time_str:<20} {cost:<10}\")
except Exception as e:
    print(f'Error: {e}')
"
}

# Extend instance time
extend_instance() {
    local instance_id="$1"
    local additional_hours="$2"
    
    if [[ -z "$instance_id" || -z "$additional_hours" ]]; then
        log "Error: Missing required parameters."
        log "Usage: vast-manager.sh extend [instance_id] [additional_hours]"
        exit 1
    fi
    
    # Update the instance end time
    python3 -c "
import json, sys, time, os

try:
    instance_id = '$instance_id'
    additional_hours = float('$additional_hours')
    instances_file = '$INSTANCES_FILE'
    
    if not os.path.exists(instances_file) or os.path.getsize(instances_file) == 0:
        print('No instances found.')
        sys.exit(1)
    
    with open(instances_file, 'r') as f:
        instances = json.load(f)
    
    for instance in instances:
        if str(instance.get('id')) == instance_id:
            current_end_time = instance.get('end_time', int(time.time()))
            new_end_time = current_end_time + (additional_hours * 3600)
            instance['end_time'] = new_end_time
            print(f'Extended instance {instance_id} by {additional_hours} hours.')
            break
    else:
        print(f'Instance {instance_id} not found.')
        sys.exit(1)
    
    with open(instances_file, 'w') as f:
        json.dump(instances, f, indent=2)
    
    # Calculate the new remaining time
    current_time = int(time.time())
    remaining_seconds = max(0, new_end_time - current_time)
    
    print(f'New end time: {time.strftime(\"%Y-%m-%d %H:%M:%S\", time.localtime(new_end_time))}')
    
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
"
    
    # Update the launchd job
    if [[ -f "$VAST_CONFIG_DIR/com.vastmanager.instance.$instance_id.plist" ]]; then
        launchctl unload "$VAST_CONFIG_DIR/com.vastmanager.instance.$instance_id.plist"
        
        # Get the new end time
        local new_end_time=$(python3 -c "
import json, sys
with open('$INSTANCES_FILE', 'r') as f:
    instances = json.load(f)
for instance in instances:
    if str(instance.get('id')) == '$instance_id':
        print(int(instance.get('end_time', 0) - time.time()))
        break
" 2>/dev/null)
        
        if [[ -n "$new_end_time" && "$new_end_time" -gt 0 ]]; then
            # Update the plist file with new time
            /usr/libexec/PlistBuddy -c "Set :StartInterval $new_end_time" "$VAST_CONFIG_DIR/com.vastmanager.instance.$instance_id.plist"
            launchctl load "$VAST_CONFIG_DIR/com.vastmanager.instance.$instance_id.plist"
            log "Updated automatic destruction timer."
        fi
    fi
}

# Destroy an instance
destroy_instance() {
    local instance_id="$1"
    local auto_mode="$2"
    
    if [[ -z "$instance_id" ]]; then
        log "Error: Missing instance ID."
        log "Usage: vast-manager.sh destroy [instance_id]"
        exit 1
    fi
    
    # Destroy the instance
    if [[ "$auto_mode" != "auto" ]]; then
        log "Destroying instance $instance_id..."
    fi
    
    vast destroy instance $instance_id >/dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        # Remove the instance from our tracking file
        python3 -c "
import json, sys, os
try:
    instance_id = '$instance_id'
    instances_file = '$INSTANCES_FILE'
    
    if os.path.exists(instances_file) and os.path.getsize(instances_file) > 0:
        with open(instances_file, 'r') as f:
            instances = json.load(f)
        
        instances = [inst for inst in instances if str(inst.get('id')) != instance_id]
        
        with open(instances_file, 'w') as f:
            json.dump(instances, f, indent=2)
except Exception as e:
    pass
"
        
        # Remove the launchd job
        if [[ -f "$VAST_CONFIG_DIR/com.vastmanager.instance.$instance_id.plist" ]]; then
            launchctl unload "$VAST_CONFIG_DIR/com.vastmanager.instance.$instance_id.plist" 2>/dev/null
            rm "$VAST_CONFIG_DIR/com.vastmanager.instance.$instance_id.plist"
        fi
        
        if [[ "$auto_mode" != "auto" ]]; then
            log "Instance $instance_id has been destroyed."
        else
            log "Instance $instance_id has been automatically destroyed due to time limit."
        fi
    else
        if [[ "$auto_mode" != "auto" ]]; then
            log "Error: Failed to destroy instance $instance_id. It may already be destroyed or you may not have permission."
        fi
    fi
}

# Main command parser
case "$1" in
    create)
        create_instance "$2" "$3" "$4"
        ;;
    status)
        show_status
        ;;
    extend)
        extend_instance "$2" "$3"
        ;;
    destroy)
        destroy_instance "$2" "$3"
        ;;
    *)
        echo "Usage: vast-manager.sh [command] [options]"
        echo "Commands:"
        echo "  create [gpu_type] [template_name] [time_limit_hours]"
        echo "      - Creates a new instance with the cheapest GPU of the specified type"
        echo "      - Connects via SSH and sets up auto-destruction timer"
        echo "  status"
        echo "      - Shows status of all tracked instances"
        echo "  extend [instance_id] [additional_hours]"
        echo "      - Extends the time limit for an instance"
        echo "  destroy [instance_id]"
        echo "      - Manually destroys an instance"
        ;;
esac
