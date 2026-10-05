/*
 * ============================================================================
 * ESP32 Bluetooth Serial Speech-to-Text Receiver Firmware
 * ============================================================================
 * Board: ESP32 Dev Module (WROOM / WROVER)
 * Core: esp32 by Espressif Systems (Arduino IDE)
 * Libraries: BluetoothSerial (built into official ESP32 Arduino Core)
 *
 * How it works:
 * 1. Initializes Bluetooth Classic Serial with device name "ESP32_Voice_Node".
 * 2. Listens for incoming lines sent from the Flutter smartphone app.
 * 3. Parses recognized voice commands (e.g., "turn on led", "turn off led", "status").
 * 4. Toggles onboard LED (GPIO 2) and transmits acknowledgment string back to the phone.
 * ============================================================================
 */

#include "BluetoothSerial.h"

// Check if Bluetooth is properly enabled in ESP32 SDK configuration
#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error Bluetooth is not enabled! Please run make menuconfig to enable it
#endif

// Create BluetoothSerial object
BluetoothSerial SerialBT;

// Name visible when scanning for Bluetooth devices on the phone
const char* deviceName = "ESP32_Voice_Node";

// Onboard LED pin (GPIO 2 on most ESP32 DevKit boards)
const int LED_PIN = 2;

// Buffer string to collect incoming serial data
String receivedBuffer = "";

void setup() {
  // Initialize hardware USB serial for debugging monitor (115200 baud)
  Serial.begin(115200);
  delay(1000);

  Serial.println("\n==================================================");
  Serial.println("   ESP32 Bluetooth Voice Command Receiver");
  Serial.println("==================================================");

  // Configure onboard LED
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW); // Start with LED OFF

  // Start Bluetooth Serial SPP
  // Note: True enables slave mode (phone connects to ESP32)
  SerialBT.begin(deviceName);
  Serial.print("Bluetooth Serial started successfully!\nDevice Name: ");
  Serial.println(deviceName);
  Serial.println("Status: Ready. Pair your smartphone to \"" + String(deviceName) + "\" in Android Settings.");

  // Blink LED twice to indicate successful boot
  for (int i = 0; i < 2; i++) {
    digitalWrite(LED_PIN, HIGH);
    delay(150);
    digitalWrite(LED_PIN, LOW);
    delay(150);
  }
}

void loop() {
  // Check if serial data is available from the connected smartphone
  if (SerialBT.available()) {
    // Read character from Bluetooth stream
    char incomingChar = SerialBT.read();

    // Check for newline delimiter '\n' or carriage return '\r'
    if (incomingChar == '\n' || incomingChar == '\r') {
      receivedBuffer.trim();

      if (receivedBuffer.length() > 0) {
        Serial.print("[Voice Command Received]: \"");
        Serial.print(receivedBuffer);
        Serial.println("\"");

        // Process and handle the voice command
        processVoiceCommand(receivedBuffer);

        // Reset buffer for subsequent messages
        receivedBuffer = "";
      }
    } else {
      // Accumulate characters
      receivedBuffer += incomingChar;
    }
  }

  // Also allow typing into Arduino IDE Serial Monitor to send back to Phone
  if (Serial.available()) {
    char c = Serial.read();
    SerialBT.write(c);
  }

  delay(5); // Yield to ESP32 RTOS watchdog
}

/**
 * Parses and executes actions based on speech text recognized by Flutter
 */
void processVoiceCommand(String command) {
  // Convert command to lowercase for case-insensitive matching
  String cmdLower = command;
  cmdLower.toLowerCase();

  if (cmdLower.indexOf("on") >= 0 || cmdLower.indexOf("turn on") >= 0 || cmdLower.indexOf("light") >= 0) {
    digitalWrite(LED_PIN, HIGH);
    Serial.println("-> Action: LED turned ON");
    // Send feedback confirmation back to Flutter smartphone app
    SerialBT.println("ACK: LED is now ON");
  } 
  else if (cmdLower.indexOf("off") >= 0 || cmdLower.indexOf("turn off") >= 0) {
    digitalWrite(LED_PIN, LOW);
    Serial.println("-> Action: LED turned OFF");
    SerialBT.println("ACK: LED is now OFF");
  }
  else if (cmdLower.indexOf("blink") >= 0) {
    Serial.println("-> Action: Blinking LED 3 times");
    SerialBT.println("ACK: Blinking LED...");
    for (int i = 0; i < 3; i++) {
      digitalWrite(LED_PIN, HIGH);
      delay(200);
      digitalWrite(LED_PIN, LOW);
      delay(200);
    }
  }
  else if (cmdLower.indexOf("status") >= 0) {
    int state = digitalRead(LED_PIN);
    String statusMsg = "ACK: Status -> LED is " + String(state == HIGH ? "ON" : "OFF");
    SerialBT.println(statusMsg);
  }
  else {
    // Generic acknowledgment for custom voice commands
    Serial.println("-> Custom Speech: " + command);
    SerialBT.println("ACK: Received \"" + command + "\"");
  }
}
