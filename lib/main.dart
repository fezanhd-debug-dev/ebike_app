import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EBikeApp());
}

class EBikeApp extends StatelessWidget {
  const EBikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'E-Bike Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        primaryColor: Colors.tealAccent,
        cardColor: const Color(0xFF1E293B),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // BLE UUIDs
  final String serviceUUID = "0000fff0-0000-1000-8000-00805f9b34fb";
  final String notifyUUID = "0000fff1-0000-1000-8000-00805f9b34fb";
  final String writeUUID = "0000fff2-0000-1000-8000-00805f9b34fb";

  // Backend Endpoints
  final String vpsSyncUrl = "http://93.127.133.163:3000/api/update-location";
  final String liveMapUrl = "http://93.127.133.163:3000/api/live-status";

  BluetoothDevice? bikeDevice;
  BluetoothCharacteristic? writeCharacteristic;

  bool isConnected = false;
  bool isConnecting = false;
  bool isLocked = false;
  int batteryPercent = 0;
  double currentSpeed = 0.0;

  Position? currentPosition;
  Timer? syncTimer;
  StreamSubscription? _scanSubscription;

  @override
  void initState() {
    super.initState();
    _initSystem();
  }

  Future<void> _initSystem() async {
    await _requestPermissions();
    _startLocationTracking();
    syncTimer = Timer.periodic(const Duration(seconds: 5), (_) => _syncToVPS());
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  void _startLocationTracking() {
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen((Position pos) {
      if (mounted) {
        setState(() {
          currentPosition = pos;
          currentSpeed = (pos.speed * 3.6).clamp(0.0, 120.0);
        });
      }
    });
  }

  Future<void> _startScanAndConnect() async {
    if (isConnecting) return;
    setState(() => isConnecting = true);

    try {
      await FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();

      List<BluetoothDevice> scannedDevices = [];
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
          if (!scannedDevices.contains(r.device)) {
            scannedDevices.add(r.device);
          }
        }
      });

      Future.delayed(const Duration(seconds: 6), () async {
        await FlutterBluePlus.stopScan();
        if (mounted) setState(() => isConnecting = false);

        if (scannedDevices.isEmpty) {
          _showToast("No BLE devices found. Make sure bike is turned ON.");
          return;
        }

        _showDeviceSelectionDialog(scannedDevices);
      });
    } catch (e) {
      if (mounted) setState(() => isConnecting = false);
      _showToast("Scan Error: $e");
    }
  }

  void _showDeviceSelectionDialog(List<BluetoothDevice> devices) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text("Select E-Bike Device"),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                String name = device.platformName.isNotEmpty ? device.platformName : "Unknown Device";
                return ListTile(
                  leading: const Icon(Icons.two_wheeler, color: Colors.tealAccent),
                  title: Text(name),
                  subtitle: Text(device.remoteId.str),
                  onTap: () {
                    Navigator.pop(context);
                    _connectToDevice(device);
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() => isConnecting = true);
    try {
      bikeDevice = device;
      await bikeDevice!.connect(timeout: const Duration(seconds: 10));

      await _setupServicesAndNotify();

      if (mounted) {
        setState(() {
          isConnected = true;
          isConnecting = false;
        });
      }
      _showToast("Connected to ${device.platformName}!");
    } catch (e) {
      if (mounted) setState(() => isConnecting = false);
      _showToast("Connection failed: $e");
    }
  }

  Future<void> _setupServicesAndNotify() async {
    if (bikeDevice == null) return;
    try {
      List<BluetoothService> services = await bikeDevice!.discoverServices();
      for (BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUUID.toLowerCase()) {
          for (BluetoothCharacteristic c in service.characteristics) {
            String charUuid = c.uuid.toString().toLowerCase();

            if (charUuid == notifyUUID.toLowerCase()) {
              await c.setNotifyValue(true);
              c.lastValueStream.listen((value) {
                if (value.isNotEmpty && mounted) {
                  setState(() {
                    batteryPercent = value.length > 8 ? value[8] : batteryPercent;
                  });
                }
              });
            } else if (charUuid == writeUUID.toLowerCase()) {
              writeCharacteristic = c;
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Services Setup Error: $e");
    }
  }

  Future<void> _toggleLockState(bool lock) async {
    if (!isConnected || writeCharacteristic == null) {
      _showToast("Bike not connected!");
      return;
    }

    try {
      List<int> command = lock ? [0xAA, 0x01, 0x01, 0xFF] : [0xAA, 0x01, 0x00, 0xFF];
      await writeCharacteristic!.write(command, withoutResponse: false);

      setState(() {
        isLocked = lock;
      });

      _showToast(lock ? "Bike Locked Remotely!" : "Bike Unlocked!");
    } catch (e) {
      _showToast("Control Command Failed: $e");
    }
  }

  Future<void> _syncToVPS() async {
    if (currentPosition == null) return;
    try {
      await http.post(
        Uri.parse(vpsSyncUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'batteryPercent': batteryPercent,
          'speedKmH': currentSpeed.round(),
          'isLocked': isLocked,
          'latitude': currentPosition!.latitude,
          'longitude': currentPosition!.longitude,
        }),
      );
    } catch (e) {
      debugPrint("VPS Sync Failed: $e");
    }
  }

  Future<void> _openLiveMap() async {
    final Uri url = Uri.parse(liveMapUrl);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      _showToast("Could not launch Map URL");
    }
  }

  void _showToast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    syncTimer?.cancel();
    bikeDevice?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('E-Bike Smart Command'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: const Color(0xFF0F172A),
        actions: [
          IconButton(
            icon: const Icon(Icons.map, color: Colors.tealAccent),
            onPressed: _openLiveMap,
            tooltip: 'Live Map Tracking',
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: ListTile(
                leading: Icon(
                  isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: isConnected ? Colors.tealAccent : Colors.redAccent,
                  size: 32,
                ),
                title: Text(
                  isConnected ? "Bike Connected" : "Bike Disconnected",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(isConnected ? "Live telemetry synced" : "Tap to scan devices"),
                trailing: isConnecting
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isConnected ? Colors.redAccent : Colors.tealAccent,
                          foregroundColor: Colors.black,
                        ),
                        onPressed: isConnected ? () => bikeDevice?.disconnect() : _startScanAndConnect,
                        child: Text(isConnected ? "Disconnect" : "Connect"),
                      ),
              ),
            ),
            const SizedBox(height: 20),

            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isLocked ? Colors.redAccent : Colors.tealAccent.withOpacity(0.4),
                    width: 8,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      currentSpeed.toStringAsFixed(0),
                      style: TextStyle(
                        fontSize: 72,
                        fontWeight: FontWeight.bold,
                        color: isLocked ? Colors.redAccent : Colors.tealAccent,
                      ),
                    ),
                    const Text("KM/H", style: TextStyle(fontSize: 16, color: Colors.grey)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent.withOpacity(0.8),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: isConnected ? () => _toggleLockState(true) : null,
                    icon: const Icon(Icons.lock, color: Colors.white),
                    label: const Text("LOCK BIKE", style: TextStyle(color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: isConnected ? () => _toggleLockState(false) : null,
                    icon: const Icon(Icons.lock_open, color: Colors.white),
                    label: const Text("UNLOCK", style: TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                _buildMetricCard("Battery", "$batteryPercent %", Icons.battery_charging_full, Colors.greenAccent),
                const SizedBox(width: 12),
                _buildMetricCard(
                  "GPS Tracking",
                  currentPosition != null ? "Active" : "Searching",
                  Icons.location_on,
                  Colors.orangeAccent,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricCard(String title, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
