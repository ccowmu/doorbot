# Doorbot Client

This repository contains the client-side code and configuration for the Raspberry Pi Door Lock Controller.

## Components

- **`doorbot_client.py`**: The main Python script that polls the server and controls the hardware (stepper motor, relay, etc.).
- **`doorbot-client.service`**: Systemd service definition to ensure the bot starts on boot and restarts on failure.
- **`setup_doorbot.sh`**: A comprehensive setup script to provision a fresh Raspberry Pi with all necessary dependencies and configurations.
- **`sounds/`**: Directory containing WAV sound files used by the system (if applicable).

## Installation

### Quick Start (Fresh Pi)

1.  Clone this repository to your local machine or directly to the Pi.
2.  Run the setup script with sudo:

    ```bash
    sudo bash setup_doorbot.sh
    ```

### Manual Installation (Using this Repo)

If you have cloned this repository to `/home/doorbot/doorbot`, you can link the service file:

1.  Install dependencies: `sudo apt install python3 python3-pip python3-rpi.gpio python3-requests`
2.  Copy or link the service file:
    ```bash
    sudo cp doorbot-client.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable doorbot-client
    sudo systemctl start doorbot-client
    ```

## Configuration

The main configuration (Server URL, GPIO pins) is currently located at the top of `doorbot_client.py`.

## Sounds

Sound files are located in the `sounds/` directory. Ensure your audio output is configured correctly on the Pi if sound playback is required.
