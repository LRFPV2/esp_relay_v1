import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const ESP32RelayControlApp());
}

class ESP32RelayControlApp extends StatelessWidget {
  const ESP32RelayControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Relay Control',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const RelayControlPage(),
    );
  }
}

class RelayControlPage extends StatefulWidget {
  const RelayControlPage({super.key});

  @override
  _RelayControlPageState createState() => _RelayControlPageState();
}

class _RelayControlPageState extends State<RelayControlPage> {
  final _ble = FlutterReactiveBle();
  String _status = 'Disconnected';
  String _receivedMessage = '';
  String? _deviceId;
  DiscoveredDevice? _targetDevice;
  QualifiedCharacteristic? _rxCharacteristic;
  QualifiedCharacteristic? _txCharacteristic;

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
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    if (statuses.values.every((status) => status.isGranted)) {
      print('Permissions granted');
      _startScanning();
    } else {
      setState(() => _status = 'Permissions denied');
      print('Permissions denied: $statuses');
    }
  }

  void _startScanning() {
    setState(() => _status = 'Scanning...');
    print('Starting BLE scan for $_targetDeviceName');
    _ble.scanForDevices(
      withServices: [_serviceUuid],
      scanMode: ScanMode.lowLatency,
    ).listen((device) {
      print('Discovered device: ${device.name}, ID: ${device.id}');
      if (device.name == _targetDeviceName) {
        _targetDevice = device;
        _deviceId = device.id;
        _connectToDevice();
      }
    }, onError: (e) {
      setState(() => _status = 'Scan error: $e');
      print('Scan error: $e');
    });
  }

  Future<void> _connectToDevice() async {
    if (_deviceId == null) return;
    setState(() => _status = 'Connecting...');
    print('Connecting to device: $_deviceId');
    _ble.connectToDevice(id: _deviceId!).listen((connectionState) {
      print('Connection state: ${connectionState.connectionState}');
      if (connectionState.connectionState == DeviceConnectionState.connected) {
        setState(() => _status = 'Connected');
        _discoverServices();
      } else if (connectionState.connectionState == DeviceConnectionState.disconnected) {
        setState(() {
          _status = 'Disconnected';
          _receivedMessage = '';
          _deviceId = null;
          _rxCharacteristic = null;
          _txCharacteristic = null;
        });
        print('Disconnected, restarting scan');
        _startScanning();
      }
    }, onError: (e) {
      setState(() => _status = 'Connection error: $e');
      print('Connection error: $e');
    });
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
      }
    } catch (e) {
      setState(() => _status = 'Service discovery error: $e');
      print('Service discovery error: $e');
    }
  }

  void _subscribeToNotifications() {
    if (_txCharacteristic == null) return;
    print('Subscribing to TX notifications');
    _ble.subscribeToCharacteristic(_txCharacteristic!).listen((data) {
      final message = String.fromCharCodes(data);
      setState(() {
        _receivedMessage = message;
      });
      print('Received notification: $message');
    }, onError: (e) {
      setState(() => _receivedMessage = 'Notification error: $e');
      print('Notification error: $e');
    });
  }

  void _sendCommand(String command) {
    if (_rxCharacteristic == null) {
      setState(() => _status = 'Not connected or characteristic unavailable');
      print('Cannot send command: RX characteristic null');
      return;
    }
    try {
      print('Sending command: $command');
      _ble.writeCharacteristicWithResponse(
        _rxCharacteristic!,
        value: command.codeUnits,
      );
      setState(() => _status = 'Sent: $command');
      print('Command sent successfully');
    } catch (e) {
      setState(() => _status = 'Write error: $e');
      print('Write error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32 Relay Control'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Status: $_status',
              style: TextStyle(
                fontSize: 18,
                color: _status == 'Connected' ? Colors.green : Colors.red,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Received: $_receivedMessage',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _status == 'Connected' ? () => _sendCommand('ON') : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
              ),
              child: const Text(
                'Turn On',
                style: TextStyle(fontSize: 18, color: Colors.white),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _status == 'Connected' ? () => _sendCommand('OFF') : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
              ),
              child: const Text(
                'Turn Off',
                style: TextStyle(fontSize: 18, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (_deviceId != null) {
      _ble.clearGattCache(_deviceId!);
      print('Cleared GATT cache for $_deviceId');
    }
    super.dispose();
  }
}