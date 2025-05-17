import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const CarCommandApp());
}

class CarCommandApp extends StatefulWidget {
  const CarCommandApp({super.key});

  @override
  _CarCommandAppState createState() => _CarCommandAppState();
}

class _CarCommandAppState extends State<CarCommandApp> {
  bool _isDarkMode = false;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isDarkMode = prefs.getBool('isDarkMode') ?? false;
    });
  }

  Future<void> _toggleTheme() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isDarkMode = !_isDarkMode;
      prefs.setBool('isDarkMode', _isDarkMode);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Car Command',
      theme: ThemeData(
        brightness: Brightness.light,
        textTheme: GoogleFonts.poppinsTextTheme(
          Theme.of(context).textTheme.apply(bodyColor: Colors.grey[900], displayColor: Colors.grey[900]),
        ),
        scaffoldBackgroundColor: Colors.white,
        primaryColor: Colors.blue[700],
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 8,
            shadowColor: Colors.black26,
          ),
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        textTheme: GoogleFonts.poppinsTextTheme(
          Theme.of(context).textTheme.apply(bodyColor: Colors.grey[200], displayColor: Colors.grey[200]),
        ),
        scaffoldBackgroundColor: Colors.grey[900],
        primaryColor: Colors.blue[300],
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 8,
            shadowColor: Colors.black54,
          ),
        ),
      ),
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: RelayControlPage(onThemeToggle: _toggleTheme, isDarkMode: _isDarkMode),
    );
  }
}

class RelayControlPage extends StatefulWidget {
  final VoidCallback onThemeToggle;
  final bool isDarkMode;

  const RelayControlPage({super.key, required this.onThemeToggle, required this.isDarkMode});

  @override
  _RelayControlPageState createState() => _RelayControlPageState();
}

class _RelayControlPageState extends State<RelayControlPage> {
  final _ble = FlutterReactiveBle();
  String _status = 'Disconnected';
  String? _deviceId;
  DiscoveredDevice? _targetDevice;
  QualifiedCharacteristic? _rxCharacteristic;
  QualifiedCharacteristic? _txCharacteristic;
  StreamSubscription? _scanSubscription;
  StreamSubscription? _connectionSubscription;
  bool _isConnecting = false;
  int _connectionAttempts = 0;
  static const int _maxConnectionAttempts = 3;

  // Toggle states for GPIOs (4 and 16 for bottom buttons)
  final Map<int, bool> _gpioStates = {
    4: false,
    16: false,
  };

  // Track button press state for visual feedback
  bool _isUnlockPressed = false;
  bool _isLockPressed = false;
  bool _isGpio4Pressed = false;
  bool _isGpio16Pressed = false;

  // UUIDs from ESP32 BLE server
  final _serviceUuid = Uuid.parse('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  final _rxUuid = Uuid.parse('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');
  final _txUuid = Uuid.parse('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');
  final _targetDeviceName = 'ESP32_Relay';

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    if (statuses.values.every((status) => status.isGranted)) {
      print('Permissions granted');
      _startScanning();
    } else {
      setState(() => _status = 'Permissions denied: $statuses');
      print('Permissions denied: $statuses');
    }
  }

  void _startScanning() {
    if (_scanSubscription != null) {
      _scanSubscription!.cancel();
      print('Previous scan canceled');
    }
    setState(() => _status = 'Scanning...');
    print('Starting BLE scan for $_targetDeviceName');
    _scanSubscription = _ble.scanForDevices(
      withServices: [_serviceUuid],
      scanMode: ScanMode.lowLatency,
    ).listen((device) {
      print('Discovered device: ${device.name}, ID: ${device.id}');
      if (device.name == _targetDeviceName && !_isConnecting) {
        _targetDevice = device;
        _deviceId = device.id;
        _scanSubscription?.cancel();
        _scanSubscription = null;
        print('Device found, scan stopped');
        _connectToDevice();
      }
    }, onError: (e) {
      setState(() => _status = 'Scan error: $e');
      print('Scan error: $e');
      Future.delayed(const Duration(seconds: 2), () {
        if (_status == 'Disconnected' || _status.contains('error')) {
          _startScanning();
        }
      });
    });
  }

  Future<void> _connectToDevice() async {
    if (_deviceId == null || _isConnecting) return;
    _isConnecting = true;
    _connectionAttempts++;
    setState(() => _status = 'Connecting... (Attempt $_connectionAttempts/$_maxConnectionAttempts)');
    print('Connecting to device: $_deviceId, attempt $_connectionAttempts');

    if (_connectionSubscription != null) {
      await _connectionSubscription!.cancel();
      print('Previous connection canceled');
    }

    _connectionSubscription = _ble
        .connectToDevice(
      id: _deviceId!,
      connectionTimeout: const Duration(seconds: 10),
    )
        .listen(
      (connectionState) {
        print('Connection state: ${connectionState.connectionState}');
        if (connectionState.connectionState == DeviceConnectionState.connected) {
          setState(() {
            _status = 'Connected';
            _connectionAttempts = 0;
          });
          _isConnecting = false;
          _discoverServices();
        } else if (connectionState.connectionState == DeviceConnectionState.disconnected) {
          setState(() {
            _status = 'Disconnected';
            _deviceId = null;
            _rxCharacteristic = null;
            _txCharacteristic = null;
            _isConnecting = false;
          });
          print('Disconnected, restarting scan');
          _startScanning();
        }
      },
      onError: (e) {
        print('Connection error: $e');
        setState(() => _status = 'Connection error: $e');
        _isConnecting = false;
        if (_connectionAttempts < _maxConnectionAttempts) {
          Future.delayed(const Duration(seconds: 2), () {
            if (_deviceId != null && !_isConnecting) {
              _connectToDevice();
            }
          });
        } else {
          setState(() {
            _status = 'Failed to connect after $_maxConnectionAttempts attempts';
            _deviceId = null;
            _connectionAttempts = 0;
          });
          print('Max connection attempts reached, restarting scan');
          _startScanning();
        }
      },
    );
  }

  Future<void> _discoverServices() async {
    if (_deviceId == null) return;
    try {
      print('Discovering services for $_deviceId');
      final services = await _ble.discoverServices(_deviceId!);
      for (var service in services) {
        if (service.serviceId == _serviceUuid) {
          print('Found service: ${_serviceUuid.toString()}');
          for (var char in service.characteristicIds) {
            if (char == _rxUuid) {
              _rxCharacteristic = QualifiedCharacteristic(
                serviceId: _serviceUuid,
                characteristicId: _rxUuid,
                deviceId: _deviceId!,
              );
              print('RX characteristic found');
            } else if (char == _txUuid) {
              _txCharacteristic = QualifiedCharacteristic(
                serviceId: _serviceUuid,
                characteristicId: _txUuid,
                deviceId: _deviceId!,
              );
              print('TX characteristic found');
              _subscribeToNotifications();
            }
          }
        }
      }
      if (_rxCharacteristic == null || _txCharacteristic == null) {
        setState(() => _status = 'Characteristics not found');
        print('Characteristics not found');
        _disconnect();
      }
    } catch (e) {
      setState(() => _status = 'Service discovery error: $e');
      print('Service discovery error: $e');
      _disconnect();
    }
  }

  void _subscribeToNotifications() {
    if (_txCharacteristic == null) {
      print('Cannot subscribe: TX characteristic null');
      return;
    }
    print('Subscribing to TX notifications');
    _ble.subscribeToCharacteristic(_txCharacteristic!).listen(
      (data) {
        final message = String.fromCharCodes(data);
        setState(() {
          _status = 'Connected';
        });
        print('Received notification: $message');
      },
      onError: (e) {
        setState(() {
          _status = 'Connected';
        });
        print('Notification error: $e');
      },
      onDone: () {
        setState(() {
          _status = 'Connected';
        });
        print('Notification stream closed');
      },
    );
  }

  void _sendCommand(String command) {
    if (_rxCharacteristic == null) {
      setState(() {
        _status = 'Not connected or characteristic unavailable';
      });
      print('Cannot send command: RX characteristic null');
      return;
    }
    try {
      print('Sending command: $command');
      _ble.writeCharacteristicWithResponse(
        _rxCharacteristic!,
        value: command.codeUnits,
      );
      setState(() {
        _status = 'Connected';
      });
      print('Command sent successfully');
    } catch (e) {
      setState(() {
        _status = 'Connected';
      });
      print('Write error: $e');
      if (e.toString().contains('GATT')) {
        _disconnect();
      }
    }
  }

  Future<void> _disconnect() async {
    if (_deviceId == null) return;
    try {
      print('Disconnecting from device: $_deviceId');
      if (_connectionSubscription != null) {
        await _connectionSubscription!.cancel();
        _connectionSubscription = null;
        print('Connection subscription canceled');
      }
    } catch (e) {
      print('Disconnect error: $e');
    }
    setState(() {
      _status = 'Disconnected';
      _deviceId = null;
      _rxCharacteristic = null;
      _txCharacteristic = null;
      _isConnecting = false;
      _connectionAttempts = 0;
    });
    try {
      await _ble.clearGattCache(_deviceId!);
      print('Cleared GATT cache for $_deviceId');
    } catch (e) {
      print('GATT cache clear error: $e');
    }
    _startScanning();
  }

  Widget _buildActionButton({
    required IconData icon,
    required LinearGradient defaultGradient,
    required bool isPressed,
    required VoidCallback? onPressed,
  }) {
    final backgroundColor = widget.isDarkMode ? Colors.grey[850]! : Colors.grey[100]!;
    final pressedGradient = LinearGradient(
      colors: [
        Color.lerp(backgroundColor, defaultGradient.colors[0], 0.6)!,
        Color.lerp(backgroundColor, defaultGradient.colors[1], 0.6)!,
      ],
    );

    return GestureDetector(
      onTapDown: (_) {
        if (_status == 'Connected') {
          setState(() {
            if (icon == Icons.lock_open) _isUnlockPressed = true;
            if (icon == Icons.lock) _isLockPressed = true;
          });
        }
      },
      onTapUp: (_) {
        if (_status == 'Connected') {
          setState(() {
            if (icon == Icons.lock_open) _isUnlockPressed = false;
            if (icon == Icons.lock) _isLockPressed = false;
          });
          onPressed?.call();
        }
      },
      onTapCancel: () {
        setState(() {
          if (icon == Icons.lock_open) _isUnlockPressed = false;
          if (icon == Icons.lock) _isLockPressed = false;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 130,
        height: 130,
        decoration: BoxDecoration(
          gradient: _status == 'Connected'
              ? (isPressed ? pressedGradient : defaultGradient)
              : const LinearGradient(colors: [Colors.grey, Colors.grey]),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: widget.isDarkMode ? Colors.black54 : Colors.black26,
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Center(
          child: Icon(
            icon,
            size: 48,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildSmallToggleButton({
    required int gpio,
    required bool isOn,
    required VoidCallback onToggle,
    required bool isPressed,
  }) {
    final defaultGradient = LinearGradient(
      colors: widget.isDarkMode
          ? [Colors.blue[500]!, Colors.blue[700]!]
          : [Colors.blue[400]!, Colors.blue[600]!],
    );
    final backgroundColor = widget.isDarkMode ? Colors.grey[850]! : Colors.grey[100]!;
    final pressedGradient = LinearGradient(
      colors: [
        Color.lerp(backgroundColor, defaultGradient.colors[0], 0.6)!,
        Color.lerp(backgroundColor, defaultGradient.colors[1], 0.6)!,
      ],
    );

    return GestureDetector(
      onTapDown: (_) {
        if (_status == 'Connected') {
          setState(() {
            if (gpio == 4) _isGpio4Pressed = true;
            if (gpio == 16) _isGpio16Pressed = true;
          });
        }
      },
      onTapUp: (_) {
        if (_status == 'Connected') {
          setState(() {
            if (gpio == 4) _isGpio4Pressed = false;
            if (gpio == 16) _isGpio16Pressed = false;
          });
          onToggle();
        }
      },
      onTapCancel: () {
        setState(() {
          if (gpio == 4) _isGpio4Pressed = false;
          if (gpio == 16) _isGpio16Pressed = false;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 130,
        height: 130,
        decoration: BoxDecoration(
          gradient: _status == 'Connected'
              ? (isPressed ? pressedGradient : defaultGradient)
              : const LinearGradient(colors: [Colors.grey, Colors.grey]),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: widget.isDarkMode ? Colors.black54 : Colors.black26,
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Center(
          child: Icon(
            isOn ? Icons.power : Icons.power_off,
            size: 48,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: widget.isDarkMode
                ? [Colors.grey[900]!, Colors.grey[850]!]
                : [Colors.white, Colors.grey[100]!],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Custom Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Car Command',
                      style: GoogleFonts.poppins(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: widget.isDarkMode ? Colors.grey[200] : Colors.grey[900],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        widget.isDarkMode ? Icons.wb_sunny : Icons.nightlight_round,
                        color: widget.isDarkMode ? Colors.blue[300] : Colors.blue[700],
                        size: 28,
                      ),
                      onPressed: widget.onThemeToggle,
                      tooltip: 'Toggle Theme',
                    ),
                  ],
                ),
              ),
              // Status
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (Widget child, Animation<double> animation) {
                    return FadeTransition(opacity: animation, child: child);
                  },
                  child: Text(
                    'Status: $_status',
                    key: ValueKey<String>(_status),
                    style: GoogleFonts.poppins(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: _status == 'Connected'
                          ? (widget.isDarkMode ? Colors.green[400] : Colors.green[600])
                          : (widget.isDarkMode ? Colors.red[400] : Colors.red[600]),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              // Lock/Unlock Buttons
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildActionButton(
                        icon: Icons.lock_open,
                        defaultGradient: LinearGradient(
                          colors: widget.isDarkMode
                              ? [Colors.green[500]!, Colors.green[700]!]
                              : [Colors.green[400]!, Colors.green[600]!],
                        ),
                        isPressed: _isUnlockPressed,
                        onPressed: () => _sendCommand('1'),
                      ),
                      const SizedBox(height: 24),
                      _buildActionButton(
                        icon: Icons.lock,
                        defaultGradient: LinearGradient(
                          colors: widget.isDarkMode
                              ? [Colors.red[500]!, Colors.red[700]!]
                              : [Colors.red[400]!, Colors.red[600]!],
                        ),
                        isPressed: _isLockPressed,
                        onPressed: () => _sendCommand('0'),
                      ),
                    ],
                  ),
                ),
              ),
              // Bottom Toggle Buttons (GPIO 4, 16)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildSmallToggleButton(
                      gpio: 4,
                      isOn: _gpioStates[4]!,
                      isPressed: _isGpio4Pressed,
                      onToggle: () {
                        setState(() {
                          _gpioStates[4] = !_gpioStates[4]!;
                        });
                        _sendCommand('4-${_gpioStates[4]! ? '1' : '0'}');
                      },
                    ),
                    const SizedBox(width: 16),
                    _buildSmallToggleButton(
                      gpio: 16,
                      isOn: _gpioStates[16]!,
                      isPressed: _isGpio16Pressed,
                      onToggle: () {
                        setState(() {
                          _gpioStates[16] = !_gpioStates[16]!;
                        });
                        _sendCommand('16-${_gpioStates[16]! ? '1' : '0'}');
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    print('Disposing RelayControlPage');
    _scanSubscription?.cancel();
    _scanSubscription = null;
    if (_deviceId != null) {
      _disconnect();
    }
    super.dispose();
  }
}