#!/usr/bin/env python3
"""
Doorbot Client - RPi.GPIO version with static reverse time
"""
import RPi.GPIO as GPIO
import time
import requests
import subprocess
import os
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

def play_sound(sound=None):
    """Play a sound file. If sound is specified, play that; otherwise pick random.
    Returns the Popen process so caller can kill it after MAX_SOUND_DURATION."""
    try:
        if sound:
            path = os.path.join(SOUNDS_DIR, sound)
            if not os.path.isfile(path):
                print(f"[{get_timestamp()}] Sound not found: {sound}, playing random")
                sound = None

        if not sound:
            wavs = [f for f in os.listdir(SOUNDS_DIR) if f.endswith('.wav')]
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

def unlock_door(pwm, sound=None):
    print(f"\n{'='*60}")
    print(f"[{get_timestamp()}] UNLOCKING DOOR")
    print(f"{'='*60}")

    sound_proc = None
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
        start_time = time.time()

        while GPIO.input(BUTTON_PIN) == GPIO.HIGH:  # HIGH = not pressed
            if time.time() - start_time > timeout:
                print(f"[{get_timestamp()}] TIMEOUT!")
                break
            time.sleep(0.1)

        pwm.stop()
        print(f"[{get_timestamp()}] Unlocked!")
        sound_proc = play_sound(sound)

        # Hold door open
        print(f"[{get_timestamp()}] Holding for {UNLOCK_HOLD_TIME}s...")
        time.sleep(UNLOCK_HOLD_TIME)

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

    try:
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
                    unlock_door(pwm, sound=status.get('sound', ''))
            time.sleep(POLL_INTERVAL)
    except KeyboardInterrupt:
        print("Shutdown")
    finally:
        pwm.stop()
        GPIO.output(RELAY_PIN, GPIO.LOW)
        GPIO.cleanup()

if __name__ == '__main__':
    main()
