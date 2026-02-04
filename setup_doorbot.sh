#!/bin/bash
# =============================================================================
# Doorbot Pi Setup — single-file, fully automatic
# Copy this script to a fresh Raspberry Pi and run:
#     sudo bash setup_doorbot.sh
# Everything else is handled.
# =============================================================================

set -e

# ── colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
warn() { echo -e "${YELLOW}  ⚠${NC}  $1"; }
fail() { echo -e "${RED}  ✗${NC} $1"; exit 1; }
header() { echo -e "\n${GREEN}── $1 ──${NC}"; }

# Run a command, check result, continue on non-critical failures
run_cmd() {
    local description="$1"
    shift
    local output
    local exitcode
    
    output=$("$@" 2>&1)
    exitcode=$?
    
    if [ $exitcode -eq 0 ]; then
        return 0
    else
        warn "$description failed (code $exitcode)"
        if [ -n "$output" ]; then
            echo "  Error details: $output" | head -3
        fi
        return 1
    fi
}

# ── logging ──────────────────────────────────────────────────────────────────
LOG_FILE="/tmp/doorbot-setup-$(date +%s).log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

trap 'echo ""; echo "Setup process exited. Full log: $LOG_FILE" >&2' EXIT

# ── constants ───────────────────────────────────────────────────────────────
SERVER_URL="http://yakko.cs.wmich.edu:8878"
PI_USER=""          # detected below
INSTALL_DIR=""      # set after user detection

# =============================================================================
# 1.  PREFLIGHT
# =============================================================================
header "Preflight checks"

# Must be root / sudo
if [ "$(id -u)" -ne 0 ]; then
    fail "This script must be run with sudo.  Run:  sudo bash setup_doorbot.sh"
fi

# Set strict error handling, but allow us to check/recover from certain errors
set +e  # Turn off exit-on-error for controlled handling below
trap 'echo "Script interrupted"; exit 1' INT TERM

# Figure out the real user who invoked sudo (not root)
if [ -n "$SUDO_USER" ]; then
    PI_USER="$SUDO_USER"
else
    # Fallback: first UID-1000 user
    PI_USER=$(awk -F: '$3==1000{print $1;exit}' /etc/passwd)
fi
[ -z "$PI_USER" ] && fail "Cannot determine the non-root user."
ok "Running as root, target user: $PI_USER"

INSTALL_DIR="/home/$PI_USER/doorbot"

# Warn if not a Raspberry Pi (don't abort — could be a test VM)
if [ -f /proc/device-tree/model ] && grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
    ok "Detected Raspberry Pi: $(cat /proc/device-tree/model | tr -d '\0')"
else
    warn "Not detected as a Raspberry Pi — continuing anyway"
fi

# =============================================================================
# 2.  INSTALL SYSTEM PACKAGES
# =============================================================================
header "Installing system packages"

# Try package install, with retries for transient network issues
PACKAGES="python3 python3-pip python3-rpi.gpio python3-requests curl"
RETRIES=3
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $RETRIES ]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    
    if apt-get update -qq 2>&1 | grep -E "error|failed" > /dev/null; then
        if [ $RETRY_COUNT -lt $RETRIES ]; then
            warn "apt-get update failed, retrying ($RETRY_COUNT/$RETRIES)..."
            sleep 5
            continue
        else
            fail "apt-get update failed after $RETRIES attempts"
        fi
    fi
    
    if apt-get install -y -qq $PACKAGES 2>&1 | grep -E "E: unable to locate|E: Unable to" > /dev/null; then
        if [ $RETRY_COUNT -lt $RETRIES ]; then
            warn "Package install failed (maybe locked), retrying ($RETRY_COUNT/$RETRIES)..."
            sleep 5
            continue
        else
            fail "Could not install required packages after $RETRIES attempts"
        fi
    fi
    
    break  # Success
done

# Verify critical packages
if ! command -v python3 &> /dev/null; then
    fail "Python3 not found after installation attempt"
fi

ok "System packages installed"

# =============================================================================
# 3.  GPIO GROUP
# =============================================================================
header "GPIO permissions"

# Check if gpio group exists (may not on all systems)
if ! getent group gpio > /dev/null 2>&1; then
    warn "GPIO group does not exist on this system — skipping gpio group setup"
    warn "This is normal on non-Pi systems or minimal Raspberry Pi OS installations"
else
    if id -nG "$PI_USER" | grep -qw gpio; then
        ok "$PI_USER already in gpio group"
    else
        if usermod -a -G gpio "$PI_USER" 2>/dev/null; then
            ok "Added $PI_USER to gpio group (takes effect after reboot or re-login)"
        else
            warn "Could not add $PI_USER to gpio group — check user permissions"
        fi
    fi
fi

# =============================================================================
# 4.  WRITE THE CLIENT SCRIPT
# =============================================================================
header "Installing doorbot client"

if ! mkdir -p "$INSTALL_DIR"; then
    fail "Could not create directory $INSTALL_DIR"
fi

CLIENT_FILE="$INSTALL_DIR/doorbot_client.py"

# Note: In the original script, this section wrote the python file content.
# Since we are now tracking the python file in git, this section of the setup script
# should ideally clone the repo or copy the file. 
# For now, I'm keeping the original script logic as a backup/reference,
# but in a real 'git-based' setup, you'd replace this with a git clone.
# However, to preserve the exact file I found, I'm keeping it as is.

cat > "$CLIENT_FILE" << 'PYTHON_EOF'
#!/usr/bin/env python3
"""
Doorbot Client - Raspberry Pi Door Lock Controller

This script polls the doorbot server and controls the door lock hardware.
Pre-configured for: http://newyakko.cs.wmich.edu:8878

Hardware Requirements:
- Raspberry Pi with GPIO access
- Stepper motor connected to GPIO 18 (PWM), GPIO 15 (direction)
- Power relay on GPIO 4
- Position sensor/button on GPIO 7

Usage:
    python3 doorbot_client.py

Auto-start on boot:
    See INSTALLATION.md for systemd service setup
"""

import RPi.GPIO as GPIO
import time
import requests
import json
from datetime import datetime

# ============================================================================
# CONFIGURATION - Change these values if needed
# ============================================================================

# Server Configuration
SERVER_URL = "http://newyakko.cs.wmich.edu:8878"
POLL_INTERVAL = 1.0  # seconds between server polls

# GPIO Pin Configuration
RELAY_PIN = 4        # Power relay control
DIRECTION_PIN = 15   # Motor direction control
PWM_PIN = 18         # Stepper motor PWM
BUTTON_PIN = 7       # Position sensor/button

# Motor Configuration
PWM_FREQUENCY = 500  # Hz
MOTOR_DUTY_CYCLE = 50  # Percent
UNLOCK_HOLD_TIME = 10  # seconds to hold door unlocked

# ============================================================================
# SETUP
# ============================================================================

def setup_gpio():
    """Initialize GPIO pins for hardware control"""
    print(f"[{get_timestamp()}] Initializing GPIO pins...")

    GPIO.setmode(GPIO.BCM)
    GPIO.setwarnings(False)

    # Set up output pins
    GPIO.setup(RELAY_PIN, GPIO.OUT, initial=GPIO.LOW)
    GPIO.setup(DIRECTION_PIN, GPIO.OUT, initial=GPIO.LOW)
    GPIO.setup(PWM_PIN, GPIO.OUT)

    # Set up input pin (position sensor)
    GPIO.setup(BUTTON_PIN, GPIO.IN, pull_up_down=GPIO.PUD_UP)

    # Initialize PWM
    pwm = GPIO.PWM(PWM_PIN, PWM_FREQUENCY)

    print(f"[{get_timestamp()}] GPIO initialization complete")
    print(f"  - Relay: GPIO {RELAY_PIN}")
    print(f"  - Direction: GPIO {DIRECTION_PIN}")
    print(f"  - PWM Motor: GPIO {PWM_PIN}")
    print(f"  - Position Sensor: GPIO {BUTTON_PIN}")

    return pwm

def get_timestamp():
    """Get current timestamp string"""
    return datetime.now().strftime('%Y-%m-%d %H:%M:%S')

# ============================================================================
# DOOR CONTROL FUNCTIONS
# ============================================================================

def unlock_door(pwm):
    """
    Execute the door unlock sequence:
    1. Activate motor to turn handle
    2. Wait for position sensor to detect unlock position
    3. Hold for UNLOCK_HOLD_TIME seconds
    4. Return handle to locked position
    """
    print(f"\n{'='*60}")
    print(f"[{get_timestamp()}] UNLOCKING DOOR")
    print(f"{'='*60}")

    try:
        # Step 1: Activate relay (power on)
        print(f"[{get_timestamp()}] Activating power relay...")
        GPIO.output(RELAY_PIN, GPIO.HIGH)
        time.sleep(0.5)

        # Step 2: Set direction and start motor
        print(f"[{get_timestamp()}] Starting motor (unlock direction)...")
        GPIO.output(DIRECTION_PIN, GPIO.HIGH)
        pwm.start(MOTOR_DUTY_CYCLE)

        # Step 3: Wait for position sensor
        print(f"[{get_timestamp()}] Waiting for unlock position...")
        timeout = 10  # Maximum wait time
        start_time = time.time()

        while GPIO.input(BUTTON_PIN) == GPIO.HIGH:  # Button not pressed
            if time.time() - start_time > timeout:
                print(f"[{get_timestamp()}] WARNING: Position sensor timeout!")
                break
            time.sleep(0.1)

        if GPIO.input(BUTTON_PIN) == GPIO.LOW:
            print(f"[{get_timestamp()}] Unlock position reached!")

        # Step 4: Stop motor
        pwm.stop()

        # Step 5: Hold unlocked position
        print(f"[{get_timestamp()}] Holding unlocked for {UNLOCK_HOLD_TIME} seconds...")
        time.sleep(UNLOCK_HOLD_TIME)

        # Step 6: Return to locked position
        print(f"[{get_timestamp()}] Returning to locked position...")
        GPIO.output(DIRECTION_PIN, GPIO.LOW)  # Reverse direction
        pwm.start(MOTOR_DUTY_CYCLE)

        # Wait for return (or timeout)
        start_time = time.time()
        while GPIO.input(BUTTON_PIN) == GPIO.LOW:  # Button still pressed
            if time.time() - start_time > timeout:
                break
            time.sleep(0.1)

        pwm.stop()

        # Step 7: Power off
        print(f"[{get_timestamp()}] Deactivating power relay...")
        GPIO.output(RELAY_PIN, GPIO.LOW)

        print(f"[{get_timestamp()}] Door lock sequence complete")
        print(f"{'='*60}\n")

    except Exception as e:
        print(f"[{get_timestamp()}] ERROR during unlock: {e}")
        # Safety: ensure motor is stopped and power is off
        pwm.stop()
        GPIO.output(RELAY_PIN, GPIO.LOW)
        raise

# ============================================================================
# SERVER COMMUNICATION
# ============================================================================

def poll_server():
    """
    Poll the server for unlock commands

    Returns:
        dict: Server response with 'letmein' status, or None if error
    """
    try:
        response = requests.get(SERVER_URL, timeout=5)
        response.raise_for_status()
        data = response.json()
        return data

    except requests.exceptions.ConnectionError:
        print(f"[{get_timestamp()}] Cannot connect to server: {SERVER_URL}")
        return None

    except requests.exceptions.Timeout:
        print(f"[{get_timestamp()}] Server timeout")
        return None

    except requests.exceptions.RequestException as e:
        print(f"[{get_timestamp()}] Server error: {e}")
        return None

    except json.JSONDecodeError:
        print(f"[{get_timestamp()}] Invalid JSON response from server")
        return None

# ============================================================================
# MAIN LOOP
# ============================================================================

def main():
    """Main program loop"""

    print("\n" + "="*60)
    print("DOORBOT CLIENT")
    print("="*60)
    print(f"Server: {SERVER_URL}")
    print(f"Poll Interval: {POLL_INTERVAL}s")
    print(f"Started: {get_timestamp()}")
    print("="*60 + "\n")

    # Initialize hardware
    pwm = setup_gpio()

    print(f"\n[{get_timestamp()}] Starting server polling...")
    print(f"[{get_timestamp()}] Press Ctrl+C to stop\n")

    consecutive_errors = 0
    max_consecutive_errors = 10

    try:
        while True:
            # Poll server
            status = poll_server()

            if status is None:
                consecutive_errors += 1
                if consecutive_errors >= max_consecutive_errors:
                    print(f"[{get_timestamp()}] Too many consecutive errors. Stopping.")
                    break
                time.sleep(POLL_INTERVAL)
                continue

            # Reset error counter on success
            consecutive_errors = 0

            # Check if unlock is requested
            if status.get('letmein', False):
                unlock_door(pwm)
            else:
                # Quiet waiting (only show dots every 10 polls)
                pass

            time.sleep(POLL_INTERVAL)

    except KeyboardInterrupt:
        print(f"\n[{get_timestamp()}] Received shutdown signal")

    except Exception as e:
        print(f"\n[{get_timestamp()}] Fatal error: {e}")

    finally:
        # Cleanup
        print(f"[{get_timestamp()}] Cleaning up GPIO...")
        pwm.stop()
        GPIO.output(RELAY_PIN, GPIO.LOW)
        GPIO.cleanup()
        print(f"[{get_timestamp()}] Shutdown complete")
        print("="*60 + "\n")

# ============================================================================
# ENTRY POINT
# ============================================================================

if __name__ == "__main__":
    main()
PYTHON_EOF

if [ ! -f "$CLIENT_FILE" ] || [ ! -s "$CLIENT_FILE" ]; then
    fail "Client file was not created or is empty"
fi

chmod +x "$CLIENT_FILE" || fail "Could not make client executable"
chown -R "$PI_USER:$PI_USER" "$INSTALL_DIR" || fail "Could not set ownership of $INSTALL_DIR"
ok "Client installed to $CLIENT_FILE ($(wc -c < "$CLIENT_FILE") bytes)"

# =============================================================================
# 5.  WRITE TEST / UTILITY SCRIPTS
# =============================================================================
header "Installing test scripts"

DOWNLOADS="/home/$PI_USER/Downloads"
if ! mkdir -p "$DOWNLOADS" 2>/dev/null; then
    warn "Could not create Downloads directory, skipping test scripts"
else
    cat > "$DOWNLOADS/Relaytest.py" << 'EOF' 2>/dev/null || warn "Could not write Relaytest.py"
import gpiozero
import time
relay = gpiozero.LED(4)

while True:
        relay.on()
        time.sleep(3)
        relay.off()
        time.sleep(3)
EOF

    cat > "$DOWNLOADS/steppertest.py" << 'EOF' 2>/dev/null || warn "Could not write steppertest.py"
import time
import gpiozero

power_switch = gpiozero.LED(4)
direction = gpiozero.LED(15)
stepper = gpiozero.PWMOutputDevice(18)
stepper.frequency = 5000
handle_check = gpiozero.Button(7)

while not handle_check.is_pressed:
        stepper.pulse(1,0,3)
EOF

    cat > "$DOWNLOADS/DoorCommand.py" << 'EOF' 2>/dev/null || warn "Could not write DoorCommand.py"
import gpiozero
import time

power_switch = gpiozero.LED(4)       # control relay to power motor at pin 7
direction = gpiozero.LED(15)         # controls motor direction at pin 10
stepper = gpiozero.PWMOutputDevice(18)  # controls the actual motor at pin 12
stepper.frequency = 500000           # the speed of pulses to the motor
handle_check = gpiozero.Button(7)    # checks where the handle is

power_switch.on()
stepper.pulse(0,0,None,True)
EOF

    chown -R "$PI_USER:$PI_USER" "$DOWNLOADS" 2>/dev/null || warn "Could not set ownership of $DOWNLOADS"
    ok "Test scripts installed to $DOWNLOADS"
fi

# =============================================================================
# 6.  DESKTOP QUICK-REFERENCE
# =============================================================================
header "Creating desktop reference"

DESKTOP="/home/$PI_USER/Desktop"
if ! mkdir -p "$DESKTOP" 2>/dev/null; then
    warn "Could not create Desktop directory, skipping desktop reference"
else
    README_FILE="$DESKTOP/DOORBOT_README.txt"
    cat > "$README_FILE" << EOF 2>/dev/null || warn "Could not write DOORBOT_README.txt"
==============================================
DOORBOT CLIENT - QUICK REFERENCE
==============================================

Your Raspberry Pi is configured and ready!

SERVER: $SERVER_URL

The doorbot client runs automatically in the background.

USEFUL COMMANDS:
----------------

# Check if client is running
sudo systemctl status doorbot-client

# View live logs
sudo journalctl -u doorbot-client -f

# Restart the client
sudo systemctl restart doorbot-client

# Stop the client
sudo systemctl stop doorbot-client

# Test server connection
curl $SERVER_URL/status


TESTING:
--------

1. Open $SERVER_URL in a browser
2. Click "Unlock Door"
3. Watch logs: sudo journalctl -u doorbot-client -f
4. Motor should activate within 1 second


CONFIGURATION:
--------------

Client location: /home/$PI_USER/doorbot/doorbot_client.py
Service file:    /etc/systemd/system/doorbot-client.service

To change settings, edit the client file and restart:
  nano ~/doorbot/doorbot_client.py
  sudo systemctl restart doorbot-client


TROUBLESHOOTING:
----------------

If the client isn't working:

1. Check service status:
   sudo systemctl status doorbot-client

2. Check logs for errors:
   sudo journalctl -u doorbot-client -n 50

3. Test server manually:
   curl $SERVER_URL/health

4. Verify network:
   ping newyakko.cs.wmich.edu

5. Run client manually for debugging:
   sudo systemctl stop doorbot-client
   python3 ~/doorbot/doorbot_client.py


GPIO PINS:
----------
  Relay         GPIO 4
  Direction     GPIO 15
  Motor PWM     GPIO 18
  Position Sensor GPIO 7

==============================================
EOF
    
    if [ -f "$README_FILE" ]; then
        chown "$PI_USER:$PI_USER" "$README_FILE" 2>/dev/null || warn "Could not set ownership of $README_FILE"
        ok "DOORBOT_README.txt placed on Desktop"
    fi
fi

# =============================================================================
# 7.  SYSTEMD SERVICE
# =============================================================================
header "Setting up systemd service"

SERVICE_FILE="/etc/systemd/system/doorbot-client.service"

cat > "$SERVICE_FILE" << 'SYSTEMD_EOF' 2>/dev/null || fail "Could not write systemd service file"
[Unit]
Description=Doorbot Client - Door Lock Controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$PI_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/doorbot_client.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

if ! systemctl daemon-reload 2>/dev/null; then
    warn "systemctl daemon-reload failed"
else
    ok "systemd daemon reloaded"
fi

if ! systemctl enable doorbot-client.service 2>/dev/null; then
    fail "Could not enable doorbot-client.service"
fi
ok "doorbot-client.service enabled"

# Make sure network-online is enabled so the service waits for WiFi
if systemctl enable NetworkManager-wait-online.service 2>/dev/null; then
    ok "NetworkManager-wait-online enabled"
else
    warn "Could not enable NetworkManager-wait-online (may not be present)"
fi

# =============================================================================
# 8.  CONNECTIVITY CHECK
# =============================================================================
header "Server connectivity"

if curl -s --max-time 5 "$SERVER_URL/health" > /dev/null 2>&1; then
    ok "Server is reachable at $SERVER_URL"
elif curl -s --max-time 5 "$SERVER_URL" > /dev/null 2>&1; then
    ok "Server appears reachable at $SERVER_URL (main endpoint)"
else
    warn "Cannot reach $SERVER_URL right now — check WiFi and network after boot"
fi

# =============================================================================
# 9.  SUMMARY & OPTIONAL START
# =============================================================================
echo ""
echo -e "${GREEN}=============================================="
echo "  Setup Complete"
echo "==============================================${NC}"
echo ""
echo "  Client:   $INSTALL_DIR/doorbot_client.py"
echo "  Service:  doorbot-client.service (enabled, starts on boot)"
echo "  Server:   $SERVER_URL"
echo "  Test scripts: ~/Downloads/{Relaytest,steppertest,DoorCommand}.py"
echo "  Reference:    ~/Desktop/DOORBOT_README.txt"
echo ""
echo "  NOTE: gpio group change requires a reboot or re-login to take effect."
echo ""

# Try to start the service (may not work yet if not on actual Pi or GPIO not available)
SERVICE_STATUS=$(systemctl is-active doorbot-client.service 2>/dev/null || echo "unknown")

if [ "$SERVICE_STATUS" = "active" ]; then
    ok "doorbot-client is already running"
elif [ "$SERVICE_STATUS" != "unknown" ]; then
    echo -n "  Start the client now? [y/N] "
    read -r reply < /dev/tty 2>/dev/null || reply="n"
    
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        if systemctl start doorbot-client.service 2>/dev/null; then
            sleep 2
            echo ""
            systemctl status doorbot-client.service --no-pager -l || true
            echo ""
            echo "  Recent logs:"
            journalctl -u doorbot-client.service -n 15 --no-pager || true
        else
            warn "Failed to start service — check permissions and GPIO availability"
        fi
    else
        echo "  Skipped.  Start later with:  sudo systemctl start doorbot-client"
    fi
else
    warn "Could not determine service status — check manually with: sudo systemctl status doorbot-client"
fi

echo ""
echo -e "${GREEN}  Done.${NC}"
echo ""
echo "  Setup log available in: /tmp/doorbot-setup-$(date +%s).log"
