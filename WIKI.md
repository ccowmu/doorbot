# Door Bot

Door Bot is the automated door lock system for the CCaWMU office. It lets club members unlock the office door remotely from a web interface — click a button, and the deadbolt turns.

---

## How It Works

```
┌──────────────┐         HTTP          ┌──────────────────┐        GPIO         ┌─────────────┐
│   Browser    │ ───────────────────▶  │  Server (yakko)  │  ◀── poll 1s ───  │  Pi Client  │
│  "Unlock!"   │                       │  :8878           │  ──── unlock ──▶  │  (doorbot)  │
└──────────────┘                       └──────────────────┘                    └──────┬──────┘
                                                                                     │
                                                                              ┌──────▼──────┐
                                                                              │ Stepper     │
                                                                              │ Motor +     │
                                                                              │ Deadbolt    │
                                                                              └─────────────┘
```

1. A user visits the web UI at `http://yakko.cs.wmich.edu:8878` and clicks **Unlock Door**
2. The server sets an unlock flag
3. The Pi client polls the server every second — when it sees the flag, it:
   - Powers the relay and drives the stepper motor to turn the deadbolt
   - Waits for the limit switch to confirm the lock is open
   - Plays a sound through the speaker
   - Holds the door unlocked for **10 seconds**
   - Reverses the motor to re-lock
4. The server can optionally specify which sound to play

---

## Hardware

| Component | Details |
|---|---|
| **Computer** | Raspberry Pi Model B Rev 2 |
| **Hostname** | `doorbot` |
| **IP Address** | `192.168.1.193` |
| **Motor** | Stepper motor driving the deadbolt via PWM |
| **Relay** | Controls motor power |
| **Limit Switch** | Detects when the lock reaches the open position |
| **Speaker** | Plays `.wav` files on unlock |

### GPIO Pinout (BCM)

| Pin | Function |
|---|---|
| GPIO 4 | Relay (motor power) |
| GPIO 15 | Motor direction |
| GPIO 18 | Motor PWM signal |
| GPIO 7 | Limit switch / position sensor |

### Motor Parameters

| Parameter | Value |
|---|---|
| PWM Frequency | 500 Hz |
| Duty Cycle | 50% |
| Unlock Hold Time | 10 seconds |
| Reverse Time | 6.5 seconds |
| Sound Max Duration | 10 seconds |

---

## Software

All source code lives in one repo: **https://github.com/ccowmu/doorbot**

The Pi automatically mirrors this repo. Push to `main` and the changes go live within 60 seconds — no SSH required.

### Repository Contents

```
doorbot/
├── doorbot_client.py        # Main client — polls server, drives hardware
├── doorbot-client.service    # Systemd unit for the client
├── doorbot-sync.sh           # Auto-sync script (fetch + reset + restart)
├── doorbot-sync.service      # Systemd unit for sync
├── doorbot-sync.timer        # Runs sync every 60 seconds
├── sync_sounds.sh            # Pulls .wav files from Proton Drive
├── sounds-sync.service       # Systemd unit for sound sync
├── sounds-sync.timer         # Runs sound sync every 5 minutes
├── setup_doorbot.sh          # Fresh Pi provisioning script
├── sounds/                   # .wav files (gitignored, synced from Proton Drive)
├── .env                      # API key (gitignored)
└── README.md
```

### Systemd Services

| Service | What It Does |
|---|---|
| `doorbot-client.service` | Runs the client. Starts on boot, restarts on failure. |
| `doorbot-sync.timer` | Every 60s: pulls from GitHub, restarts client if code changed. |
| `sounds-sync.timer` | Every 5min: syncs `.wav` files from Proton Drive via rclone. |

### Auto-Sync (GitHub → Pi)

The `doorbot-sync.sh` script runs every minute via systemd timer:

1. `git fetch origin main`
2. Compares local HEAD to remote — if identical, does nothing
3. If there are changes: `git reset --hard origin/main`
4. Checks if any `.service` or `.timer` files changed — if so, copies them to `/etc/systemd/system/` and reloads systemd
5. Restarts `doorbot-client.service`

**To deploy a change:** just push to `main` on GitHub. Done.

---

## Sounds

The doorbot plays a random `.wav` file each time the door unlocks. The server can also request a specific sound by name.

### Adding Sounds

Upload `.wav` files to the shared **Proton Drive** `sounds` folder. They sync to the Pi automatically every 5 minutes via rclone. The local cache is capped at **500 MB** — when it fills up, the oldest files are deleted first.

### Proton Drive Setup (One-Time)

If rclone needs to be reconfigured on the Pi:

```bash
sudo apt install rclone
rclone config
# Create a new remote named "protondrive"
# Storage type: protondrive
# Follow browser prompts to authenticate

sudo cp sounds-sync.service sounds-sync.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sounds-sync.timer
```

---

## Common Commands

```bash
# SSH into the Pi
ssh doorbot@192.168.1.193

# Check if the client is running
sudo systemctl status doorbot-client

# View live logs
sudo journalctl -u doorbot-client -f

# Restart the client
sudo systemctl restart doorbot-client

# Force an immediate sync from GitHub
/home/doorbot/doorbot/doorbot-sync.sh

# Check sync timer status
systemctl status doorbot-sync.timer

# Manually sync sounds from Proton Drive
sudo -u doorbot bash /home/doorbot/doorbot/sync_sounds.sh

# Test server connection
curl http://yakko.cs.wmich.edu:8878/status
```

---

## Configuration

Configuration is at the top of `doorbot_client.py`:

| Variable | Default | Description |
|---|---|---|
| `SERVER_URL` | `http://yakko.cs.wmich.edu:8878` | Server to poll |
| `POLL_INTERVAL` | `1.0` | Seconds between polls |
| `UNLOCK_HOLD_TIME` | `10` | Seconds to hold door open |
| `REVERSE_TIME` | `6.5` | Seconds to run motor in reverse |
| `MAX_SOUND_DURATION` | `10` | Kill sound playback after this many seconds |

The API key is stored in `/home/doorbot/doorbot/.env` (not in the repo).

---

## Troubleshooting

**Client won't start:**
```bash
sudo journalctl -u doorbot-client -n 50    # Check recent logs
sudo systemctl status doorbot-client        # Check service state
```

**Door doesn't unlock:**
- Check the relay is powered: `GPIO 4` should go HIGH
- Check motor direction: `GPIO 15`
- Check limit switch: `GPIO 7` reads LOW when pressed
- Run the client manually for debug output:
  ```bash
  sudo systemctl stop doorbot-client
  sudo python3 /home/doorbot/doorbot/doorbot_client.py
  ```

**Sync not working:**
```bash
systemctl status doorbot-sync.timer         # Is the timer active?
sudo journalctl -u doorbot-sync -n 20       # Check sync logs
git -C /home/doorbot/doorbot fetch origin    # Can it reach GitHub?
```

**No sound playing:**
- Check audio output: `aplay -l`
- Test manually: `aplay -D hw:0,0 /home/doorbot/doorbot/sounds/some_file.wav`
- Check if sounds exist: `ls /home/doorbot/doorbot/sounds/*.wav`

---

## Network

| Endpoint | Address |
|---|---|
| **Web UI** | http://yakko.cs.wmich.edu:8878 |
| **Pi SSH** | `doorbot@192.168.1.193` |
| **Source Code** | https://github.com/ccowmu/doorbot |
