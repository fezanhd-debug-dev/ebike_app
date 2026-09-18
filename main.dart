import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const EBikeApp());

class EBikeApp extends StatelessWidget {
  const EBikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'E-Bike Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: Colors.tealAccent,
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
  // Bluetooth Service & Characteristic UUIDs
  final String serviceUUID = "0000fff0-0000-1000-8000-00805f9b34fb";
  final String notifyUUID = "0000fff1-0000-1000-8000-00805f9b34fb";
  
  // VPS Server API Endpoint
  final String vpsUrl = "http://93.127.133.163:3000/api/update-location";

  BluetoothDevice? bikeDevice;
  bool isConnected = false;
  bool isConnecting = false;
  int batteryPercent = 0;
  double currentSpeed = 0.0;
  Position? currentPosition;
  Timer? syncTimer;

  @override
  void initState() {
    super.initState();
    _initSystem();
  }

  Future<void> _initSystem() async {
    await _requestPermissions();
    _startLocationTracking();
    
    // Har 5 seconds baad automatic VPS sync
    syncTimer = Timer.periodic(const Duration(seconds: 5), (_) => _syncToVPS());
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  void _startLocationTracking() {
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen((Position pos) {
      setState(() {
        currentPosition = pos;
        // Convert m/s to km/h
        currentSpeed = (pos.speed * 3.6).clamp(0.0, 120.0);
      });
    });
  }

  Future<void> _connectToBike() async {
    setState(() => isConnecting = true);
    
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

      FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult r in results) {
          if (r.device.platformName.contains("M1365") || 
              r.advertisementData.serviceUuids.contains(Guid(serviceUUID))) {
            
            await FlutterBluePlus.stopScan();
            bikeDevice = r.device;
            await bikeDevice!.connect();
            
            setState(() {
              isConnected = true;
              isConnecting = false;
            });

            _setupNotify();
            break;
          }
        }
      });
    } catch (e) {
      setState(() => isConnecting = false);
      debugPrint("Connection error: $e");
    }
  }

  void _setupNotify() async {
    if (bikeDevice == null) return;
    List<BluetoothService> services = await bikeDevice!.discoverServices();
    
    for (BluetoothService service in services) {
      if (service.uuid.toString() == serviceUUID) {
        for (BluetoothCharacteristic c in service.characteristics) {
          if (c.uuid.toString() == notifyUUID) {
            await c.setNotifyValue(true);
            c.lastValueStream.listen((value) {
              if (value.isNotEmpty) {
                setState(() {
                  batteryPercent = value.length > 8 ? value[8] : batteryPercent;
                });
              }
            });
          }
        }
      }
    }
  }

  Future<void> _syncToVPS() async {
    if (currentPosition == null) return;

    try {
      final response = await http.post(
        Uri.parse(vpsUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'batteryPercent': batteryPercent,
          'isCharging': false,
          'speedKmH': currentSpeed.round(),
          'latitude': currentPosition!.latitude,
          'longitude': currentPosition!.longitude,
        }),
      );
      debugPrint("VPS Sync Response: ${response.statusCode}");
    } catch (e) {
      debugPrint("VPS Sync Failed: $e");
    }
  }

  @override
  void dispose() {
    syncTimer?.cancel();
    bikeDevice?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('E-Bike Live Panel'),
        centerTitle: true,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            Card(
              color: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              child: ListTile(
                leading: Icon(
                  isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: isConnected ? Colors.tealAccent : Colors.redAccent,
                  size: 32,
                ),
                title: Text(isConnected ? "Bike Connected" : "Bike Disconnected"),
                subtitle: Text(isConnected ? "Receiving live telemetry" : "Tap button to search"),
                trailing: isConnecting
                    ? const CircularProgressIndicator()
                    : ElevatedButton(
                        onPressed: isConnected ? null : _connectToBike,
                        child: Text(isConnected ? "Active" : "Connect"),
                      ),
              ),
            ),
            const SizedBox(height: 30),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.tealAccent.withOpacity(0.3), width: 8),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      currentSpeed.toStringAsFixed(0),
                      style: const TextStyle(fontSize: 72, fontWeight: FontWeight.bold, color: Colors.tealAccent),
                    ),
                    const Text("KM/H", style: TextStyle(fontSize: 18, color: Colors.grey)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 30),
            Row(
              children: [
                _buildInfoCard("Battery", "$batteryPercent %", Icons.battery_charging_full, Colors.greenAccent),
                const SizedBox(width: 15),
                _buildInfoCard(
                  "GPS Signal",
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

  Widget _buildInfoCard(String title, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
