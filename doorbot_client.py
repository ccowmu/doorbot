#!/usr/bin/env python3
"""
Doorbot Client - RPi.GPIO version with static reverse time
"""
import RPi.GPIO as GPIO
import time
import requests
import subprocess
import os
import json
import random
from datetime import datetime

API_KEY = os.getenv("YAKKO_API_KEY", "")

SERVER_URL = "http://yakko.cs.wmich.edu:8878"
POLL_INTERVAL = 1.0
UNLOCK_HOLD_TIME = 10
REVERSE_TIME = 6.5  # Static time to reverse motor
MAX_SOUND_DURATION = 10  # seconds, kill aplay after this

# GPIO Pin Configuration
RELAY_PIN = 4
DIRECTION_PIN = 15
PWM_PIN = 18
BUTTON_PIN = 7

# Motor Configuration
PWM_FREQUENCY = 500
MOTOR_DUTY_CYCLE = 50

# Sound
SOUNDS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sounds')

# Local backup log file
LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'unlock_log.json')

# Track state for health reporting
start_time = time.time()
last_unlock_time = None

def get_timestamp():
    return datetime.now().strftime('%Y-%m-%d %H:%M:%S')

def setup_gpio():
    GPIO.setmode(GPIO.BCM)
    GPIO.setwarnings(False)
    GPIO.setup(RELAY_PIN, GPIO.OUT, initial=GPIO.LOW)
    GPIO.setup(DIRECTION_PIN, GPIO.OUT, initial=GPIO.LOW)
    GPIO.setup(PWM_PIN, GPIO.OUT)
    GPIO.setup(BUTTON_PIN, GPIO.IN, pull_up_down=GPIO.PUD_UP)
    pwm = GPIO.PWM(PWM_PIN, PWM_FREQUENCY)
    print(f"[{get_timestamp()}] GPIO initialized")
    return pwm

def poll_server():
    try:
        response = requests.get(SERVER_URL, headers={"Authorization": "Bearer " + API_KEY}, timeout=5)
        response.raise_for_status()
        return response.json()
    except:
        return None

def get_sound_list():
    """Return list of available .wav filenames."""
    try:
        return [f for f in os.listdir(SOUNDS_DIR) if f.endswith('.wav')]
    except Exception:
        return []

def sync_sound_list():
    """Push available sound list to the server."""
    try:
        sounds = get_sound_list()
        requests.post(
            SERVER_URL + "/sounds",
            json={"sounds": sounds},
            headers={"Authorization": "Bearer " + API_KEY},
            timeout=5,
        )
        print(f"[{get_timestamp()}] Synced {len(sounds)} sounds to server")
    except Exception as e:
        print(f"[{get_timestamp()}] Sound list sync error: {e}")

def log_unlock(sound_played, sender=''):
    """Log an unlock event to the server and local backup file."""
    global last_unlock_time
    last_unlock_time = time.time()
    event = {
        'timestamp': get_timestamp(),
        'epoch': int(time.time()),
        'sound': sound_played or 'random',
        'sender': sender,
    }

    # POST to server
    try:
        requests.post(
            SERVER_URL + "/log",
            json=event,
            headers={"Authorization": "Bearer " + API_KEY},
            timeout=5,
        )
        print(f"[{get_timestamp()}] Unlock event logged to server")
    except Exception as e:
        print(f"[{get_timestamp()}] Failed to log to server: {e}")

    # Local backup
    try:
        log_data = []
        if os.path.isfile(LOG_FILE):
            with open(LOG_FILE, 'r') as f:
                log_data = json.load(f)
        log_data.append(event)
        # Keep last 100 entries
        log_data = log_data[-100:]
        with open(LOG_FILE, 'w') as f:
            json.dump(log_data, f, indent=2)
    except Exception as e:
        print(f"[{get_timestamp()}] Failed to write local log: {e}")

def send_heartbeat():
    """Send health heartbeat to the server."""
    try:
        cpu_temp = None
        try:
            with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
                cpu_temp = round(int(f.read().strip()) / 1000.0, 1)
        except Exception:
            pass

        mem_info = {}
        try:
            with open('/proc/meminfo', 'r') as f:
                for line in f:
                    parts = line.split()
                    if parts[0] in ('MemTotal:', 'MemAvailable:'):
                        mem_info[parts[0].rstrip(':')] = int(parts[1])
        except Exception:
            pass

        mem_used_pct = None
        if 'MemTotal' in mem_info and 'MemAvailable' in mem_info:
            mem_used_pct = round(100 * (1 - mem_info['MemAvailable'] / mem_info['MemTotal']), 1)

        heartbeat = {
            'timestamp': get_timestamp(),
            'uptime_seconds': int(time.time() - start_time),
            'last_unlock': datetime.fromtimestamp(last_unlock_time).strftime('%Y-%m-%d %H:%M:%S') if last_unlock_time else None,
            'cpu_temp_c': cpu_temp,
            'memory_used_pct': mem_used_pct,
        }

        requests.post(
            SERVER_URL + "/health/doorbot",
            json=heartbeat,
            headers={"Authorization": "Bearer " + API_KEY},
            timeout=5,
        )
        print(f"[{get_timestamp()}] Heartbeat sent")
    except Exception as e:
        print(f"[{get_timestamp()}] Heartbeat error: {e}")

def play_sound(sound=None):
    """Play a sound file. If sound is 'none', skip playback (sneaky mode).
    If sound is specified, play that; otherwise pick random.
    Returns the Popen process so caller can kill it after MAX_SOUND_DURATION."""
    if sound == "none":
        print(f"[{get_timestamp()}] Sneaky mode — no sound")
        return None
    try:
        if sound:
            path = os.path.join(SOUNDS_DIR, sound)
            if not os.path.isfile(path):
                print(f"[{get_timestamp()}] Sound not found: {sound}, playing random")
                sound = None

        if not sound:
            wavs = get_sound_list()
            if not wavs:
                print(f"[{get_timestamp()}] No .wav files in {SOUNDS_DIR}")
                return None
            sound = random.choice(wavs)
            path = os.path.join(SOUNDS_DIR, sound)

        proc = subprocess.Popen(['aplay', '-D', 'hw:0,0', path])
        print(f"[{get_timestamp()}] Playing {sound}")
        return proc
    except Exception as e:
        print(f"[{get_timestamp()}] Sound error: {e}")
        return None

def unlock_door(pwm, sound=None, hold_time=0, sender=''):
    print(f"\n{'='*60}")
    print(f"[{get_timestamp()}] UNLOCKING DOOR")
    if sender:
        print(f"[{get_timestamp()}] Triggered by: {sender}")
    print(f"{'='*60}")

    # Use configurable hold time from server, fall back to default
    actual_hold_time = hold_time if hold_time > 0 else UNLOCK_HOLD_TIME

    sound_proc = None
    sound_played = sound
    try:
        # Power on relay
        print(f"[{get_timestamp()}] Activating relay...")
        GPIO.output(RELAY_PIN, GPIO.HIGH)
        time.sleep(0.5)

        # Set direction to unlock and start motor
        print(f"[{get_timestamp()}] Starting motor (unlock)...")
        GPIO.output(DIRECTION_PIN, GPIO.HIGH)
        pwm.start(MOTOR_DUTY_CYCLE)

        # Wait until limit switch triggers
        timeout = 30
        start = time.time()

        while GPIO.input(BUTTON_PIN) == GPIO.HIGH:  # HIGH = not pressed
            if time.time() - start > timeout:
                print(f"[{get_timestamp()}] TIMEOUT!")
                break
            time.sleep(0.1)

        pwm.stop()
        print(f"[{get_timestamp()}] Unlocked!")
        sound_proc = play_sound(sound)

        # Log the unlock event
        log_unlock(sound_played, sender)

        # Hold door open
        print(f"[{get_timestamp()}] Holding for {actual_hold_time}s...")
        time.sleep(actual_hold_time)

        # Kill sound if still playing after max duration
        if sound_proc and sound_proc.poll() is None:
            sound_proc.kill()
            print(f"[{get_timestamp()}] Sound stopped (max {MAX_SOUND_DURATION}s)")

        # Reverse for static time
        print(f"[{get_timestamp()}] Reversing for {REVERSE_TIME}s...")
        GPIO.output(DIRECTION_PIN, GPIO.LOW)
        pwm.start(MOTOR_DUTY_CYCLE)
        time.sleep(REVERSE_TIME)
        pwm.stop()

        # Power off
        print(f"[{get_timestamp()}] Relay off")
        GPIO.output(RELAY_PIN, GPIO.LOW)
        print(f"[{get_timestamp()}] Done")
        print(f"{'='*60}\n")

    except Exception as e:
        print(f"[{get_timestamp()}] ERROR: {e}")
        if sound_proc and sound_proc.poll() is None:
            sound_proc.kill()
        pwm.stop()
        GPIO.output(RELAY_PIN, GPIO.LOW)

def main():
    print(f"\nDOORBOT CLIENT - {SERVER_URL}")
    pwm = setup_gpio()
    consecutive_errors = 0
    poll_count = 0

    try:
        sync_sound_list()
        send_heartbeat()
        while True:
            status = poll_server()
            if status is None:
                consecutive_errors += 1
                if consecutive_errors >= 10:
                    print("Too many errors")
                    break
            else:
                consecutive_errors = 0
                if status.get('letmein', False):
                    unlock_door(
                        pwm,
                        sound=status.get('sound', ''),
                        hold_time=int(status.get('hold_time', 0)),
                        sender=status.get('sender', ''),
                    )
            poll_count += 1
            if poll_count >= 60:
                sync_sound_list()
                send_heartbeat()
                poll_count = 0
            time.sleep(POLL_INTERVAL)
    except KeyboardInterrupt:
        print("Shutdown")
    finally:
        pwm.stop()
        GPIO.output(RELAY_PIN, GPIO.LOW)
        GPIO.cleanup()

if __name__ == '__main__':
    main()
