import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
class BikeConfig {
  // BLE identifiers (16-bit short form). Confirmed with nRF Connect:
  // service FFF0, FFF1 = notify, FFF2 = write / write-no-response.
  static const String serviceId = 'fff0';
  static const String notifyId = 'fff1';
  static const String writeId = 'fff2';

  // Backend
  static const String vpsSyncUrl = 'http://93.127.133.163:3000/api/update-location';
  static const String liveMapUrl = 'http://93.127.133.163:3000/api/live-status';

  // Bike protocol.
  // NOTE: these bytes are NOT verified against the bike manufacturer's
  // protocol. Confirm them (or replace them) before relying on lock/unlock.
  static const List<int> lockCommand = [0xAA, 0x01, 0x01, 0xFF];
  static const List<int> unlockCommand = [0xAA, 0x01, 0x00, 0xFF];

  // Position of the battery byte inside a notification packet (unverified).
  static const int batteryByteIndex = 8;

  static const int connectAttempts = 3;
}

// ---------------------------------------------------------------------------
// BLE service: scan / connect / discover / notify / write
// ---------------------------------------------------------------------------
class BikeBleService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;

  final StreamController<bool> _connectedCtrl = StreamController<bool>.broadcast();
  final StreamController<List<int>> _packetCtrl = StreamController<List<int>>.broadcast();

  Stream<bool> get connectionStream => _connectedCtrl.stream;
  Stream<List<int>> get packetStream => _packetCtrl.stream;

  /// True only when the write characteristic was found and notify is active.
  bool get isReady => _device != null && _writeChar != null;

  String get deviceName {
    final n = _device?.platformName ?? '';
    return n.isNotEmpty ? n : (_device?.remoteId.str ?? 'bike');
  }

  /// flutter_blue_plus prints 16-bit UUIDs in short form ("fff0"), not the full
  /// 128-bit form, so we must compare both representations.
  static bool _uuidMatches(Guid uuid, String shortId) {
    final s = uuid.toString().toLowerCase();
    return s == shortId || s.startsWith('0000$shortId-');
  }

  Future<List<ScanResult>> scan({Duration timeout = const Duration(seconds: 6)}) async {
    final found = <String, ScanResult>{};
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        found[r.device.remoteId.str] = r;
      }
    });
    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }

    final list = found.values.toList();
    list.sort((a, b) {
      final an = a.device.platformName.isNotEmpty ? 0 : 1;
      final bn = b.device.platformName.isNotEmpty ? 0 : 1;
      if (an != bn) return an - bn;
      return b.rssi.compareTo(a.rssi);
    });
    return list;
  }

  /// Connects and prepares the bike. Retries because Android often returns
  /// GATT error 133 on the first attempt (seen in nRF Connect as well).
  Future<void> connect(BluetoothDevice device) async {
    await disconnect();

    Object? lastError;
    for (var attempt = 1; attempt <= BikeConfig.connectAttempts; attempt++) {
      try {
        await device.connect(timeout: const Duration(seconds: 15));
        await _discoverAndSubscribe(device);

        _device = device;
        _stateSub = device.connectionState.listen((s) {
          if (s == BluetoothConnectionState.disconnected) {
            _onLinkLost();
          }
        });
        if (!_connectedCtrl.isClosed) _connectedCtrl.add(true);
        return;
      } catch (e) {
        lastError = e;
        debugPrint('BLE connect attempt $attempt failed: $e');
        await _cleanup(device);
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    throw lastError ?? Exception('Unable to connect');
  }

  Future<void> _discoverAndSubscribe(BluetoothDevice device) async {
    final services = await device.discoverServices();

    BluetoothCharacteristic? notifyChar;
    BluetoothCharacteristic? writeChar;

    for (final s in services) {
      if (!_uuidMatches(s.uuid, BikeConfig.serviceId)) continue;
      for (final c in s.characteristics) {
        if (_uuidMatches(c.uuid, BikeConfig.notifyId)) notifyChar = c;
        if (_uuidMatches(c.uuid, BikeConfig.writeId)) writeChar = c;
      }
    }

    if (notifyChar == null || writeChar == null) {
      throw Exception('Bike service (FFF0/FFF1/FFF2) not found');
    }

    await notifyChar.setNotifyValue(true);
    await _notifySub?.cancel();
    _notifySub = notifyChar.lastValueStream.listen((value) {
      if (value.isNotEmpty && !_packetCtrl.isClosed) {
        _packetCtrl.add(value);
      }
    });
    _writeChar = writeChar;
  }

  Future<void> send(List<int> data) async {
    final c = _writeChar;
    if (c == null) throw StateError('Bike is not ready');
    await c.write(data, withoutResponse: !c.properties.write);
  }

  void _onLinkLost() {
    _notifySub?.cancel();
    _notifySub = null;
    _stateSub?.cancel();
    _stateSub = null;
    _writeChar = null;
    _device = null;
    if (!_connectedCtrl.isClosed) _connectedCtrl.add(false);
  }

  Future<void> _cleanup(BluetoothDevice device) async {
    await _notifySub?.cancel();
    _notifySub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    _writeChar = null;
    try {
      await device.disconnect();
    } catch (_) {}
  }

  Future<void> disconnect() async {
    final d = _device;
    if (d == null) return;
    await _cleanup(d);
    _device = null;
    if (!_connectedCtrl.isClosed) _connectedCtrl.add(false);
  }

  Future<void> dispose() async {
    await disconnect();
    await _connectedCtrl.close();
    await _packetCtrl.close();
  }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------
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
  final BikeBleService _ble = BikeBleService();

  StreamSubscription<bool>? _connSub;
  StreamSubscription<List<int>>? _packetSub;
  StreamSubscription<Position>? _positionSub;
  Timer? _syncTimer;

  bool isConnected = false;
  bool isConnecting = false;
  bool isLocked = false;
  int? batteryPercent; // null until a valid value is received
  double currentSpeed = 0.0;
  String? lastPacketHex;

  Position? currentPosition;
  bool _syncing = false;
  bool _locationErrorShown = false;

  @override
  void initState() {
    super.initState();

    _connSub = _ble.connectionStream.listen((connected) {
      if (!mounted) return;
      setState(() {
        isConnected = connected;
        if (!connected) {
          batteryPercent = null;
          lastPacketHex = null;
        }
      });
      if (!connected) _showToast('Bike disconnected');
    });
    _packetSub = _ble.packetStream.listen(_onPacket);

    _initSystem();
  }

  Future<void> _initSystem() async {
    await Permission.locationWhenInUse.request();
    _startLocationTracking();
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (_) => _syncToVPS());
  }

  Future<bool> _ensureBlePermissions() async {
    final result = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final scanOk = result[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk = result[Permission.bluetoothConnect]?.isGranted ?? false;
    if (!scanOk || !connectOk) {
      _showToast('Bluetooth permission is required. Please allow it in Settings.');
      return false;
    }
    return true;
  }

  void _startLocationTracking() {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen(
      (Position pos) {
        if (!mounted) return;
        setState(() {
          currentPosition = pos;
          currentSpeed = (pos.speed * 3.6).clamp(0.0, 120.0);
        });
      },
      onError: (Object e) {
        debugPrint('Location error: $e');
        if (!_locationErrorShown) {
          _locationErrorShown = true;
          _showToast('GPS unavailable. Turn on Location.');
        }
      },
    );
  }

  // ---- Telemetry ----------------------------------------------------------
  void _onPacket(List<int> data) {
    if (!mounted || data.isEmpty) return;

    int? battery;
    final idx = BikeConfig.batteryByteIndex;
    if (data.length > idx && data[idx] >= 0 && data[idx] <= 100) {
      battery = data[idx];
    }

    setState(() {
      lastPacketHex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      if (battery != null) batteryPercent = battery;
    });
  }

  // ---- Connect flow -------------------------------------------------------
  Future<void> _onConnectPressed() async {
    if (isConnecting) return;

    if (!await _ensureBlePermissions()) return;

    try {
      final adapter = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 3));
      if (adapter != BluetoothAdapterState.on) {
        _showToast('Please turn Bluetooth ON.');
        return;
      }
    } catch (_) {
      _showToast('Bluetooth is not available.');
      return;
    }

    setState(() => isConnecting = true);
    List<ScanResult> results;
    try {
      results = await _ble.scan();
    } catch (e) {
      if (mounted) setState(() => isConnecting = false);
      _showToast('Scan error: $e');
      return;
    }
    if (!mounted) return;
    setState(() => isConnecting = false);

    if (results.isEmpty) {
      _showToast('No BLE devices found. Make sure the bike is ON.');
      return;
    }
    _showDeviceSelectionDialog(results);
  }

  void _showDeviceSelectionDialog(List<ScanResult> results) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('Select E-Bike Device'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: results.length,
              itemBuilder: (context, index) {
                final device = results[index].device;
                final name = device.platformName.isNotEmpty ? device.platformName : 'Unknown Device';
                return ListTile(
                  leading: const Icon(Icons.two_wheeler, color: Colors.tealAccent),
                  title: Text(name),
                  subtitle: Text(device.remoteId.str),
                  onTap: () {
                    Navigator.pop(dialogContext);
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
      await _ble.connect(device);
      _showToast('Connected to ${_ble.deviceName}');
    } catch (e) {
      _showToast('Connection failed: $e');
    } finally {
      if (mounted) setState(() => isConnecting = false);
    }
  }

  // ---- Commands -----------------------------------------------------------
  Future<void> _toggleLockState(bool lock) async {
    if (!_ble.isReady) {
      _showToast('Bike is not ready. Please reconnect.');
      return;
    }
    try {
      await _ble.send(lock ? BikeConfig.lockCommand : BikeConfig.unlockCommand);
      if (mounted) setState(() => isLocked = lock);
      _showToast(lock ? 'Lock command sent' : 'Unlock command sent');
    } catch (e) {
      _showToast('Command failed: $e');
    }
  }

  // ---- Backend ------------------------------------------------------------
  Future<void> _syncToVPS() async {
    final pos = currentPosition;
    if (pos == null || _syncing) return;
    _syncing = true;
    try {
      await http
          .post(
            Uri.parse(BikeConfig.vpsSyncUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'batteryPercent': batteryPercent ?? 0,
              'speedKmH': currentSpeed.round(),
              'isLocked': isLocked,
              'latitude': pos.latitude,
              'longitude': pos.longitude,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('VPS sync failed: $e');
    } finally {
      _syncing = false;
    }
  }

  Future<void> _openLiveMap() async {
    final url = Uri.parse(BikeConfig.liveMapUrl);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      _showToast('Could not launch map URL');
    }
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _packetSub?.cancel();
    _positionSub?.cancel();
    _syncTimer?.cancel();
    _ble.dispose();
    super.dispose();
  }

  // ---- UI -----------------------------------------------------------------
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
                  isConnected ? 'Bike Connected' : 'Bike Disconnected',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(isConnected ? 'Live telemetry synced' : 'Tap to scan devices'),
                trailing: isConnecting
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isConnected ? Colors.redAccent : Colors.tealAccent,
                          foregroundColor: Colors.black,
                        ),
                        onPressed: isConnected ? () => _ble.disconnect() : _onConnectPressed,
                        child: Text(isConnected ? 'Disconnect' : 'Connect'),
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
                    const Text('KM/H', style: TextStyle(fontSize: 16, color: Colors.grey)),
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
                    label: const Text('LOCK BIKE', style: TextStyle(color: Colors.white)),
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
                    label: const Text('UNLOCK', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                _buildMetricCard(
                  'Battery',
                  batteryPercent != null ? '$batteryPercent %' : '-- %',
                  Icons.battery_charging_full,
                  Colors.greenAccent,
                ),
                const SizedBox(width: 12),
                _buildMetricCard(
                  'GPS Tracking',
                  currentPosition != null ? 'Active' : 'Searching',
                  Icons.location_on,
                  Colors.orangeAccent,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Last packet: ${lastPacketHex ?? 'waiting for data...'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.grey, fontSize: 11),
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
