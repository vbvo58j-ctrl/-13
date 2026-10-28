import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bluetooth_classic_service.dart';

/// Local Wi-Fi/LAN transport. It discovers peers on the same broadcast
/// domain and transfers newline-delimited JSON packets over TCP.
/// This is a transport path, not an Internet relay or end-to-end encryption.
class LocalNetworkService {
  LocalNetworkService._();
  static final LocalNetworkService instance = LocalNetworkService._();

  static const int _discoveryPort = 39772;
  static const int _tcpPort = 39771;
  final StreamController<BlousabEvent> _events =
      StreamController<BlousabEvent>.broadcast();
  final Map<String, _LanPeer> _peers = <String, _LanPeer>{};

  RawDatagramSocket? _udp;
  ServerSocket? _server;
  Timer? _discoveryTimer;
  String _userId = '';
  String _userName = 'مستخدم بلوساب';
  bool _running = false;

  Stream<BlousabEvent> get events => _events.stream;
  bool get isRunning => _running;
  int get peerCount => _peers.length;
  List<Map<String, String>> get discoveredPeers => _peers.values.map((p) => <String, String>{'id': p.id, 'name': p.name, 'address': p.address}).toList(growable: false);

  Future<void> start({required String userId, required String userName}) async {
    _userId = userId;
    _userName = userName;
    if (_running) {
      _sendDiscovery();
      return;
    }
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _tcpPort,
          shared: true);
      _server!.listen(_acceptClient, onError: (Object error) {
        _emitError('تعذر استقبال اتصال الشبكة المحلية: $error');
      });
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4,
          _discoveryPort,
          reuseAddress: true, reusePort: true);
      _udp!.broadcastEnabled = true;
      _udp!.listen(_onUdpEvent, onError: (Object error) {
        _emitError('تعذر اكتشاف أجهزة الشبكة المحلية: $error');
      });
      _running = true;
      _sendDiscovery();
      _discoveryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _sendDiscovery();
        _prunePeers();
      });
      _events.add(const BlousabEvent(type: 'lanStarted'));
    } catch (e) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    _running = false;
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _udp?.close();
    _udp = null;
    await _server?.close();
    _server = null;
    _peers.clear();
    _events.add(const BlousabEvent(type: 'lanStopped'));
  }

  void _sendDiscovery() {
    final udp = _udp;
    if (!_running || udp == null) return;
    final bytes = utf8.encode(jsonEncode({
      'kind': 'blousab_discovery',
      'peerId': _userId,
      'name': _userName,
      'port': _tcpPort,
    }));
    try {
      udp.send(bytes, InternetAddress('255.255.255.255'), _discoveryPort);
    } catch (_) {}
  }

  void _onUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final udp = _udp;
    if (udp == null) return;
    Datagram? datagram;
    while ((datagram = udp.receive()) != null) {
      try {
        final packet = jsonDecode(utf8.decode(datagram!.data));
        if (packet is! Map || packet['peerId']?.toString() == _userId) continue;
        final kind = packet['kind']?.toString();
        final address = datagram!.address.address;
        if (kind == 'blousab_discovery') {
          final peerId = packet['peerId']?.toString() ?? '';
          if (peerId.isEmpty) continue;
          _peers[peerId] = _LanPeer(
            id: peerId,
            name: packet['name']?.toString() ?? 'جهاز على الشبكة',
            address: address,
            lastSeen: DateTime.now(),
          );
          final reply = utf8.encode(jsonEncode({
            'kind': 'blousab_peer',
            'peerId': _userId,
            'name': _userName,
            'port': _tcpPort,
          }));
          udp.send(reply, datagram!.address, _discoveryPort);
        } else if (kind == 'blousab_peer') {
          final peerId = packet['peerId']?.toString() ?? '';
          if (peerId.isEmpty) continue;
          _peers[peerId] = _LanPeer(
            id: peerId,
            name: packet['name']?.toString() ?? 'جهاز على الشبكة',
            address: address,
            lastSeen: DateTime.now(),
          );
        }
      } catch (_) {}
    }
  }

  void _prunePeers() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    _peers.removeWhere((_, peer) => peer.lastSeen.isBefore(cutoff));
  }

  void _acceptClient(Socket socket) {
    final address = socket.remoteAddress.address;
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      _events.add(BlousabEvent(
        type: 'message',
        address: 'lan:$address',
        name: 'شبكة محلية',
        message: line,
      ));
    }, onError: (Object error) {
      _emitError('خطأ في اتصال الشبكة المحلية: $error');
    }, onDone: () => socket.destroy());
  }

  Future<void> broadcastMessage(String payload) async {
    if (!_running) throw StateError('الشبكة المحلية غير مفعلة');
    if (_peers.isEmpty) throw StateError('لم يُعثر على أجهزة أخرى في الشبكة المحلية');
    final targets = _peers.values.toList(growable: false);
    var sent = 0;
    Object? lastError;
    for (final peer in targets) {
      Socket? socket;
      try {
        socket = await Socket.connect(peer.address, _tcpPort,
            timeout: const Duration(seconds: 3));
        socket.write('$payload\n');
        await socket.flush();
        sent++;
      } catch (e) {
        lastError = e;
      } finally {
        try { await socket?.close(); } catch (_) { socket?.destroy(); }
      }
    }
    if (sent == 0) throw StateError('تعذر الإرسال عبر الشبكة المحلية: $lastError');
  }

  void _emitError(String message) {
    _events.add(BlousabEvent(type: 'lanError', message: message));
  }
}

class _LanPeer {
  final String id;
  final String name;
  final String address;
  DateTime lastSeen;
  _LanPeer({required this.id, required this.name, required this.address, required this.lastSeen});
}