// =============================================================================
// File: lib/main.dart
// Description: Production Flutter App for ESP32 Bluetooth Speech-to-Text Controller
// Dependencies: flutter_bluetooth_serial, speech_to_text, permission_handler
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock orientation to portrait for consistent handheld usability
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const Esp32VoiceControllerApp());
}

class Esp32VoiceControllerApp extends StatelessWidget {
  const Esp32VoiceControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Voice Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D9488),
          brightness: Brightness.light,
          primary: const Color(0xFF0F766E),
          surface: const Color(0xFFF8FAFC),
        ),
        cardTheme: const CardTheme(
          elevation: 2,
          margin: EdgeInsets.zero,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF14B8A6),
          brightness: Brightness.dark,
          primary: const Color(0xFF14B8A6),
          surface: const Color(0xFF0F172A),
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        cardTheme: const CardTheme(
          elevation: 2,
          color: Color(0xFF1E293B),
          margin: EdgeInsets.zero,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const VoiceControllerHomePage(),
    );
  }
}

class VoiceControllerHomePage extends StatefulWidget {
  const VoiceControllerHomePage({super.key});

  @override
  State<VoiceControllerHomePage> createState() =>
      _VoiceControllerHomePageState();
}

class _VoiceControllerHomePageState extends State<VoiceControllerHomePage>
    with SingleTickerProviderStateMixin {
  // ---------------------------------------------------------------------------
  // Bluetooth Serial State
  // ---------------------------------------------------------------------------
  final FlutterBluetoothSerial _bluetooth = FlutterBluetoothSerial.instance;
  BluetoothConnection? _connection;
  BluetoothDevice? _selectedDevice;
  bool _isConnected = false;
  bool _isConnecting = false;
  List<BluetoothDevice> _pairedDevices = [];
  StreamSubscription<BluetoothDiscoveryResult>? _discoveryStreamSubscription;

  // ---------------------------------------------------------------------------
  // Speech-to-Text State
  // ---------------------------------------------------------------------------
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  bool _isListening = false;
  String _lastWords = '';
  double _confidenceLevel = 0.0;
  String _transmissionStatus = 'Ready to dictate';

  // ---------------------------------------------------------------------------
  // Animation Controller for pulsing microphone effect
  // ---------------------------------------------------------------------------
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Scroll controller for the recognized text display card
  final ScrollController _textScrollController = ScrollController();

  // History log of messages sent to ESP32
  final List<String> _sentHistory = [];

  @override
  void initState() {
    super.initState();

    // Setup pulsing animation for recording indicator
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Initial sequence: request runtime permissions, then init modules
    _initializeAllServices();
  }

  @override
  void dispose() {
    // Avoid memory leaks: clean up controllers, streams, and connections
    _pulseController.dispose();
    _textScrollController.dispose();
    _discoveryStreamSubscription?.cancel();
    _connection?.dispose();
    super.dispose();
  }

  // ===========================================================================
  // 1. Permissions & Initialization
  // ===========================================================================
  Future<void> _initializeAllServices() async {
    await _requestPermissions();
    await _initSpeech();
    await _initBluetooth();
  }

  /// Requests all necessary permissions for Bluetooth Serial and Audio Recording.
  /// Android 12+ (API 31+) mandates BLUETOOTH_SCAN and BLUETOOTH_CONNECT.
  Future<void> _requestPermissions() async {
    final Map<Permission, PermissionStatus> statuses = await [
      Permission.microphone,
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location, // Location is required on older Android for Bluetooth discovery
    ].request();

    final micDenied = statuses[Permission.microphone]?.isDenied ?? false;
    final btConnectDenied =
        statuses[Permission.bluetoothConnect]?.isDenied ?? false;

    if (micDenied || btConnectDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Microphone and Bluetooth permissions are required for speech and ESP32 link.',
            ),
            backgroundColor: Colors.deepOrange,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Initializes the speech recognition engine
  Future<void> _initSpeech() async {
    try {
      _speechEnabled = await _speechToText.initialize(
        onError: (errorNotification) {
          debugPrint('Speech error: ${errorNotification.errorMsg}');
          setState(() {
            _isListening = false;
            _transmissionStatus = 'Speech error: ${errorNotification.errorMsg}';
          });
        },
        onStatus: (status) {
          debugPrint('Speech status: $status');
          if (status == 'done' || status == 'notListening') {
            setState(() {
              _isListening = false;
            });
          }
        },
      );
      setState(() {});
    } catch (e) {
      debugPrint('Failed to initialize speech engine: $e');
    }
  }

  /// Checks Bluetooth adapter status and fetches paired devices
  Future<void> _initBluetooth() async {
    try {
      final bool? isEnabled = await _bluetooth.isEnabled;
      if (isEnabled == false) {
        await _bluetooth.requestEnable();
      }
      await _loadPairedDevices();
    } catch (e) {
      debugPrint('Error initializing Bluetooth: $e');
    }
  }

  /// Loads already paired / bonded devices from Android OS
  Future<void> _loadPairedDevices() async {
    try {
      final List<BluetoothDevice> devices =
          await _bluetooth.getBondedDevices();
      setState(() {
        _pairedDevices = devices;
      });
    } catch (e) {
      debugPrint('Error getting bonded devices: $e');
    }
  }

  // ===========================================================================
  // 2. Bluetooth Connection Logic
  // ===========================================================================

  /// Connects to selected Bluetooth Device (ESP32) via RFCOMM SPP
  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() {
      _isConnecting = true;
      _selectedDevice = device;
      _transmissionStatus = 'Connecting to ${device.name ?? "Device"}...';
    });

    try {
      // Establish Bluetooth RFCOMM connection to device MAC address
      final connection = await BluetoothConnection.toAddress(device.address);

      setState(() {
        _connection = connection;
        _isConnected = true;
        _isConnecting = false;
        _transmissionStatus = 'Connected to ${device.name ?? device.address}';
      });

      _showSnackBar(
        'Connected to ${device.name ?? "ESP32"}!',
        Colors.teal,
      );

      // Listen for incoming serial data from ESP32
      _connection!.input?.listen(
        (Uint8List data) {
          final incoming = utf8.decode(data).trim();
          debugPrint('ESP32 says: $incoming');
          if (incoming.isNotEmpty && mounted) {
            _showSnackBar('ESP32: $incoming', Colors.blueGrey);
          }
        },
        onDone: () {
          // Triggered when ESP32 disconnects or goes out of range
          _onDisconnected('ESP32 closed the connection');
        },
        onError: (dynamic error) {
          _onDisconnected('Connection error: $error');
        },
      );
    } catch (e) {
      setState(() {
        _isConnecting = false;
        _isConnected = false;
        _connection = null;
        _transmissionStatus = 'Failed to connect: $e';
      });

      _showSnackBar(
        'Could not connect. Ensure ESP32 is powered & paired.',
        Colors.redAccent,
      );
    }
  }

  /// Disconnects the active Bluetooth Serial link
  Future<void> _disconnect() async {
    setState(() {
      _transmissionStatus = 'Disconnecting...';
    });

    try {
      await _connection?.finish();
      await _connection?.close();
    } catch (e) {
      debugPrint('Error disconnecting: $e');
    } finally {
      setState(() {
        _connection = null;
        _isConnected = false;
        _isConnecting = false;
        _transmissionStatus = 'Disconnected';
      });
      _showSnackBar('Disconnected from device', Colors.grey);
    }
  }

  void _onDisconnected(String reason) {
    if (!mounted) return;
    setState(() {
      _connection = null;
      _isConnected = false;
      _isConnecting = false;
      _transmissionStatus = reason;
    });
    _showSnackBar(reason, Colors.orange);
  }

  /// Sends a string over the Bluetooth Serial RFCOMM connection to ESP32
  Future<void> _sendDataToEsp32(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    if (_connection == null || !_isConnected) {
      _showSnackBar(
        'Bluetooth is not connected! Text not sent to ESP32.',
        Colors.amber.shade900,
      );
      return;
    }

    try {
      // Append a newline '\n' delimiter so ESP32's Serial.readStringUntil('\n') knows the packet ended
      final packet = '$trimmed\n';
      final Uint8List bytes = Uint8List.fromList(utf8.encode(packet));

      _connection!.output.add(bytes);
      await _connection!.output.allSent;

      setState(() {
        _transmissionStatus = 'Sent "$trimmed" (${bytes.length} bytes)';
        _sentHistory.insert(0, '${DateTime.now().toIso8601String().substring(11, 19)}: $trimmed');
        if (_sentHistory.length > 20) _sentHistory.removeLast();
      });

      debugPrint('Sent to ESP32: $packet');
    } catch (e) {
      setState(() {
        _transmissionStatus = 'Error sending data: $e';
      });
      _showSnackBar('Failed to send serial data', Colors.red);
    }
  }

  // ===========================================================================
  // 3. Speech-to-Text Handling
  // ===========================================================================

  /// Starts capturing speech from the phone microphone
  void _startListening() async {
    if (!_speechEnabled) {
      _showSnackBar('Speech recognition engine unavailable', Colors.red);
      await _initSpeech();
      return;
    }

    // Clear previous phrase or maintain for appending
    setState(() {
      _lastWords = '';
      _isListening = true;
      _transmissionStatus = 'Listening to your voice...';
    });

    await _speechToText.listen(
      onResult: _onSpeechResult,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      localeId: 'en_US', // You can change to locale of choice e.g. 'es_ES', 'ar_EG'
      cancelOnError: true,
      listenMode: ListenMode.confirmation,
    );

    setState(() {});
  }

  /// Stops speech listening session
  void _stopListening() async {
    await _speechToText.stop();
    setState(() {
      _isListening = false;
      _transmissionStatus = 'Stopped listening';
    });
  }

  /// Callback when speech recognizer yields partial or final result
  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() {
      _lastWords = result.recognizedWords;
      _confidenceLevel = result.confidence;
    });

    // Auto-scroll to bottom of card
    if (_textScrollController.hasClients) {
      _textScrollController.animateTo(
        _textScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }

    // Instantly transmit recognized text to ESP32
    // Both partial and final updates can be sent, or only final
    if (result.finalResult && _lastWords.trim().isNotEmpty) {
      _sendDataToEsp32(_lastWords);
    }
  }

  void _showSnackBar(String message, Color backgroundColor) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ===========================================================================
  // 4. Modal Bottom Sheet for Device Selection
  // ===========================================================================
  void _openDeviceSelectorSheet() {
    _loadPairedDevices();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            return Container(
              height: MediaQuery.of(context).size.height * 0.65,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 16,
                    offset: Offset(0, -4),
                  )
                ],
              ),
              child: Column(
                children: [
                  // Grab handle
                  Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white24 : Colors.black12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // Header
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Theme.of(context).primaryColor.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.bluetooth_searching,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Paired Devices',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  'Select your ESP32 board',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark ? Colors.white54 : Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          tooltip: 'Refresh devices',
                          onPressed: () async {
                            await _loadPairedDevices();
                            setModalState(() {});
                          },
                        ),
                      ],
                    ),
                  ),

                  const Divider(height: 1),

                  // Device list
                  Expanded(
                    child: _pairedDevices.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.bluetooth_disabled,
                                    size: 48,
                                    color: isDark ? Colors.white30 : Colors.black26,
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'No Paired Bluetooth Devices Found',
                                    style: TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '1. Open phone Settings > Bluetooth\n2. Put ESP32 in pairing mode\n3. Pair with it (PIN: 1234 or automatic)\n4. Tap refresh above',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark ? Colors.white54 : Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _pairedDevices.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final device = _pairedDevices[index];
                              final isCurrent = _selectedDevice?.address == device.address && _isConnected;
                              final isEsp = (device.name?.toLowerCase().contains('esp') ?? false) ||
                                  (device.name?.toLowerCase().contains('voice') ?? false);

                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isCurrent
                                      ? Colors.teal
                                      : (isEsp ? Colors.indigo : Colors.grey.shade400),
                                  child: Icon(
                                    isEsp ? Icons.memory : Icons.devices,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        device.name ?? 'Unknown Device',
                                        style: const TextStyle(fontWeight: FontWeight.w600),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (isEsp)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.teal.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'ESP32',
                                          style: TextStyle(fontSize: 10, color: Colors.teal, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                  ],
                                ),
                                subtitle: Text(
                                  device.address,
                                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                                ),
                                trailing: isCurrent
                                    ? const Chip(
                                        label: Text('Connected', style: TextStyle(fontSize: 11)),
                                        backgroundColor: Color(0xFFCCFBF1),
                                        labelStyle: TextStyle(color: Color(0xFF0F766E)),
                                      )
                                    : OutlinedButton(
                                        style: OutlinedButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        onPressed: () {
                                          Navigator.of(context).pop();
                                          _connectToDevice(device);
                                        },
                                        child: const Text('Connect'),
                                      ),
                                onTap: () {
                                  Navigator.of(context).pop();
                                  _connectToDevice(device);
                                },
                              );
                            },
                          ),
                  ),

                  // Bottom advice banner
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                    child: Text(
                      'Tip: ESP32 uses Classic Bluetooth SPP (Serial Port Profile). Ensure Bluetooth is enabled.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ===========================================================================
  // 5. Main UI Build
  // ===========================================================================
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.mic, size: 22),
            SizedBox(width: 8),
            Text(
              'ESP32 Voice Bridge',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
            ),
          ],
        ),
        actions: [
          // Bluetooth quick toggle / info
          IconButton(
            icon: Icon(
              _isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
              color: _isConnected ? Colors.tealAccent : null,
            ),
            tooltip: 'Bluetooth Settings',
            onPressed: _openDeviceSelectorSheet,
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About & Help',
            onPressed: _showHelpDialog,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---------------------------------------------------------------
              // A. Status Card: Bluetooth Connection State
              // ---------------------------------------------------------------
              _buildBluetoothStatusCard(isDark),

              const SizedBox(height: 16),

              // ---------------------------------------------------------------
              // B. Center Spacious Card: Speech-To-Text Output in Real-Time
              // ---------------------------------------------------------------
              Expanded(
                child: _buildSpeechDisplayCard(isDark),
              ),

              const SizedBox(height: 12),

              // Transmission status bar
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isListening
                          ? Icons.record_voice_over
                          : (_isConnected ? Icons.check_circle_outline : Icons.pause_circle_outline),
                      size: 16,
                      color: _isListening
                          ? Colors.redAccent
                          : (_isConnected ? Colors.teal : Colors.grey),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _transmissionStatus,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white70 : Colors.black87,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_isListening)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'REC',
                          style: TextStyle(fontSize: 10, color: Colors.redAccent, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 72), // Leave space for FloatingActionButton
            ],
          ),
        ),
      ),

      // -----------------------------------------------------------------------
      // C. Large Mic Floating Action Button (FAB)
      // -----------------------------------------------------------------------
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _buildMicrophoneFab(),
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Modern Bluetooth Status Card
  // ---------------------------------------------------------------------------
  Widget _buildBluetoothStatusCard(bool isDark) {
    Color cardColor;
    Color borderColor;
    Color statusBadgeColor;
    String statusTitle;
    String statusSubtitle;

    if (_isConnected) {
      cardColor = isDark ? const Color(0xFF064E3B) : const Color(0xFFECFDF5);
      borderColor = isDark ? const Color(0xFF059669) : const Color(0xFFA7F3D0);
      statusBadgeColor = const Color(0xFF10B981);
      statusTitle = 'Connected';
      statusSubtitle = _selectedDevice?.name ?? _selectedDevice?.address ?? 'ESP32 Serial';
    } else if (_isConnecting) {
      cardColor = isDark ? const Color(0xFF78350F) : const Color(0xFFFFFBEB);
      borderColor = isDark ? const Color(0xFFD97706) : const Color(0xFFFDE68A);
      statusBadgeColor = const Color(0xFFF59E0B);
      statusTitle = 'Connecting...';
      statusSubtitle = _selectedDevice?.name ?? 'Establishing RFCOMM link';
    } else {
      cardColor = isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
      borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
      statusBadgeColor = const Color(0xFF94A3B8);
      statusTitle = 'Disconnected';
      statusSubtitle = 'Select paired ESP32 to establish link';
    }

    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Icon badge with pulse dot
          Stack(
            alignment: Alignment.topRight,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: statusBadgeColor.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  _isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                  color: statusBadgeColor,
                  size: 26,
                ),
              ),
              Positioned(
                right: 2,
                top: 2,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: statusBadgeColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isDark ? const Color(0xFF1E293B) : Colors.white,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(width: 14),

          // Information text
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      statusTitle,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _isConnected ? const Color(0xFF059669) : null,
                      ),
                    ),
                    if (_isConnected) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.bolt, color: Color(0xFF10B981), size: 16),
                    ]
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  statusSubtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Connect / Disconnect Action Button
          _isConnected
              ? OutlinedButton.icon(
                  onPressed: _disconnect,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.link_off, size: 16),
                  label: const Text('Disconnect', style: TextStyle(fontSize: 12)),
                )
              : FilledButton.icon(
                  onPressed: _isConnecting ? null : _openDeviceSelectorSheet,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0F766E),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: _isConnecting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.bluetooth_searching, size: 16),
                  label: Text(_isConnecting ? 'Linking...' : 'Connect',
                      style: const TextStyle(fontSize: 12)),
                ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Spacious Center Text Card for Real-Time Speech Output
  // ---------------------------------------------------------------------------
  Widget _buildSpeechDisplayCard(bool isDark) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          width: 1,
        ),
      ),
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top card bar: Header & action icons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F766E).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.record_voice_over,
                        color: Color(0xFF0F766E),
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Live Speech Output',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),

                Row(
                  children: [
                    if (_confidenceLevel > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.teal.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Confidence: ${(_confidenceLevel * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.teal,
                          ),
                        ),
                      ),
                    const SizedBox(width: 4),
                    // Quick copy button
                    if (_lastWords.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: 'Copy text',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _lastWords));
                          _showSnackBar('Copied to clipboard', Colors.teal);
                        },
                      ),
                    // Resend to ESP32 button
                    if (_lastWords.isNotEmpty && _isConnected)
                      IconButton(
                        icon: const Icon(Icons.send_rounded, size: 18),
                        tooltip: 'Resend to ESP32',
                        onPressed: () => _sendDataToEsp32(_lastWords),
                      ),
                    // Clear text
                    if (_lastWords.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: 'Clear text',
                        onPressed: () {
                          setState(() {
                            _lastWords = '';
                            _confidenceLevel = 0.0;
                          });
                        },
                      ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 16),

            // Scrollable real-time words container
            Expanded(
              child: _lastWords.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _isListening ? Icons.hearing : Icons.mic_none_outlined,
                              size: 56,
                              color: _isListening
                                  ? Colors.teal
                                  : (isDark ? Colors.white24 : Colors.black26),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _isListening
                                  ? 'Listening... Speak into your phone microphone'
                                  : 'Tap the mic button below to start dictating',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white70 : Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: Text(
                                'Recognized words are automatically transmitted to your ESP32 microcontroller via Serial SPP.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark ? Colors.white38 : Colors.black45,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Scrollbar(
                      controller: _textScrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _textScrollController,
                        physics: const BouncingScrollPhysics(),
                        child: SelectableText(
                          _lastWords,
                          style: TextStyle(
                            fontSize: 22,
                            height: 1.4,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.2,
                            color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                    ),
            ),

            const SizedBox(height: 8),

            // Bottom word count & characters
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _lastWords.trim().isEmpty
                      ? '0 words'
                      : '${_lastWords.trim().split(RegExp(r'\\s+')).length} words | ${_lastWords.length} chars',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
                if (_isConnected)
                  Row(
                    children: [
                      const Icon(Icons.sync, size: 12, color: Colors.teal),
                      const SizedBox(width: 4),
                      Text(
                        'Live Serial Stream Active',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.tealAccent : Colors.teal.shade700,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Large Mic Floating Action Button with Pulsing Wave
  // ---------------------------------------------------------------------------
  Widget _buildMicrophoneFab() {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: _isListening ? _pulseAnimation.value : 1.0,
          child: SizedBox(
            width: 76,
            height: 76,
            child: FittedBox(
              child: FloatingActionButton.large(
                onPressed: _speechToText.isNotListening
                    ? _startListening
                    : _stopListening,
                elevation: _isListening ? 12 : 6,
                backgroundColor: _isListening
                    ? const Color(0xFFDC2626) // Red when listening
                    : const Color(0xFF0F766E), // Teal when idle
                foregroundColor: Colors.white,
                shape: const CircleBorder(),
                tooltip: _isListening ? 'Stop Listening' : 'Start Speech to Text',
                child: Icon(
                  _isListening ? Icons.mic : Icons.mic_none,
                  size: 38,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Dialog: Help & Troubleshooting
  // ---------------------------------------------------------------------------
  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.help_outline, color: Color(0xFF0F766E)),
            SizedBox(width: 8),
            Text('ESP32 Voice Bridge Help'),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'How it works:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 6),
              Text(
                '1. Pair the ESP32 in your phone\'s native Android Bluetooth Settings.\n'
                '2. Open this app and tap "Connect" on the top status card.\n'
                '3. Choose your ESP32 from the paired device list.\n'
                '4. Tap the large microphone button and speak.\n'
                '5. Converted text is transmitted to the ESP32 over Bluetooth Serial (SPP) with a newline (\\n) delimiter.',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              SizedBox(height: 12),
              Text(
                'ESP32 Baud Rate:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 4),
              Text(
                'Bluetooth Serial SPP operates without hardware baud limitations, but Serial.begin(115200) is standard for USB monitor debugging.',
                style: TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
