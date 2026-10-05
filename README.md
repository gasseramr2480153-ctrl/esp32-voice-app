# ESP32 Voice Controller (Flutter + Bluetooth Serial)

A complete Flutter application for Android connecting to an ESP32 microcontroller over Classic Bluetooth Serial (RFCOMM / SPP) and streaming live Speech-To-Text (STT) output in real time.

---

## 📱 Features

1. **Bluetooth Serial Link**:
   - Uses `flutter_bluetooth_serial` to connect via RFCOMM / SPP.
   - Discovers bonded ESP32 devices via a modern modal bottom sheet.
   - Auto-reconnect and instant disconnect handling.
2. **Google Speech-To-Text**:
   - Uses `speech_to_text` to stream live vocal transcription.
   - Pulsing microphone floating action button (FAB).
   - Real-time word counter and confidence score.
3. **Android 12+ Permission Hardening**:
   - Uses `permission_handler` to prompt for `RECORD_AUDIO`, `BLUETOOTH_CONNECT`, and `BLUETOOTH_SCAN` at runtime.
4. **Instant Transmission**:
   - Automatically encodes recognized phrases to UTF-8 and sends over Bluetooth Serial with a newline (`\n`) packet delimiter.

---

## 🚀 Step-by-Step Setup Guide

### 1. Hardware Requirements
- ESP32 Development Board (e.g. ESP32 DevKit V1 / WROOM-32).
- Micro-USB / USB-C Cable to connect ESP32 to PC.
- Android Smartphone with Bluetooth and Microphone.

### 2. Flashing ESP32 Firmware
1. Open Arduino IDE.
2. Install the ESP32 board package via Board Manager: `esp32 by Espressif Systems`.
3. Select your ESP32 board and COM port.
4. Paste the code from `esp32/esp32_speech_receiver.ino`.
5. Upload the sketch and open Serial Monitor at **115200 baud**.
6. You will see: `Bluetooth Serial started successfully! Device Name: ESP32_Voice_Node`.

### 3. Pairing Phone with ESP32
1. On your Android phone, go to **Settings > Bluetooth**.
2. Tap **Pair new device**.
3. Select **ESP32_Voice_Node**.
4. Confirm pairing (PIN is typically `1234` or automatic).

### 4. Running the Flutter App
```bash
# 1. Fetch dependencies
flutter pub get

# 2. Connect Android phone via USB with USB Debugging enabled
flutter devices

# 3. Run the application
flutter run
```

### 5. Using the App
- Tap Connect on the status card.
- Select ESP32_Voice_Node from the bottom sheet.
- Tap the Microphone button and speak (e.g., "Turn on the light", "Blink", "Status").
- Watch the ESP32 Serial Monitor print the received string and toggle the onboard LED!
