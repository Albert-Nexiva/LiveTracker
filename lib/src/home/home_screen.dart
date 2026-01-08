import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../auth/auth_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.user});

  final User user;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final fm.MapController _mapController = fm.MapController();
  StreamSubscription<Position>? _positionSub;

  Position? _position;
  String? _locationError;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    _startLocationTracking();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  Future<void> _startLocationTracking() async {
    setState(() {
      _requesting = true;
      _locationError = null;
    });

    try {
      final status = await _ensureLocationPermission();
      if (!status.ok) {
        setState(() {
          _locationError = status.message;
          _requesting = false;
        });
        return;
      }

      await _positionSub?.cancel();

      const settings = LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5,
      );

      _positionSub = Geolocator.getPositionStream(locationSettings: settings)
          .listen((pos) {
        setState(() {
          _position = pos;
        });

        final center = LatLng(pos.latitude, pos.longitude);
        _mapController.move(center, 16);
      }, onError: (_) {
        if (!mounted) return;
        setState(() {
          _locationError = 'Failed to read location updates.';
        });
      });

      // Prime the UI quickly with a single immediate read.
      final current = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
      );
      setState(() {
        _position = current;
      });

      final center = LatLng(current.latitude, current.longitude);
      _mapController.move(center, 16);
    } catch (_) {
      setState(() {
        _locationError = 'Unable to start location tracking.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _requesting = false;
        });
      }
    }
  }

  Future<_PermissionStatus> _ensureLocationPermission() async {
    if (kIsWeb) {
      return const _PermissionStatus(
        ok: false,
        message: 'Location tracking is supported on mobile apps only.',
      );
    }

    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      return const _PermissionStatus(
        ok: false,
        message: 'Location services are disabled. Please enable GPS.',
      );
    }

    final permission = Platform.isIOS
        ? Permission.locationWhenInUse
        : Permission.location;

    var status = await permission.status;
    if (status.isDenied) {
      status = await permission.request();
    }

    if (status.isDenied || status.isRestricted || status.isLimited) {
      return const _PermissionStatus(
        ok: false,
        message: 'Location permission denied.',
      );
    }

    if (status.isPermanentlyDenied) {
      return const _PermissionStatus(
        ok: false,
        message:
            'Location permission permanently denied. Open settings to grant access.',
      );
    }

    return const _PermissionStatus(ok: true);
  }

  List<fm.Marker> _markers() {
    final pos = _position;
    if (pos == null) return const [];

    return [
      fm.Marker(
        point: LatLng(pos.latitude, pos.longitude),
        width: 48,
        height: 48,
        child: const Icon(Icons.location_pin, size: 42),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final pos = _position;
    final email = widget.user.email ?? '(no email)';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Tracker'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: () async {
              await AuthService(FirebaseAuth.instance).signOut();
            },
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Signed in as: $email',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _requesting ? null : _startLocationTracking,
                    icon: const Icon(Icons.my_location),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
            ),
          ),
          if (_locationError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _locationError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_locationError!.contains('Open settings'))
                    OutlinedButton(
                      onPressed: () async {
                        await Geolocator.openAppSettings();
                      },
                      child: const Text('Settings'),
                    ),
                  if (_locationError!.contains('disabled'))
                    OutlinedButton(
                      onPressed: () async {
                        await Geolocator.openLocationSettings();
                      },
                      child: const Text('Enable GPS'),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: _LocationInfo(position: pos),
          ),
          Expanded(
            child: ClipRect(
              child: fm.FlutterMap(
                mapController: _mapController,
                options: const fm.MapOptions(
                  initialCenter: LatLng(0, 0),
                  initialZoom: 2,
                ),
                children: [
                  fm.TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.live_tracker',
                  ),
                  fm.MarkerLayer(markers: _markers()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationInfo extends StatelessWidget {
  const _LocationInfo({required this.position});

  final Position? position;

  @override
  Widget build(BuildContext context) {
    final p = position;
    if (p == null) {
      return Row(
        children: const [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Fetching current location...'),
        ],
      );
    }

    final time = DateFormat.Hms().format(p.timestamp.toLocal());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Latitude:  ${p.latitude.toStringAsFixed(6)}'),
        Text('Longitude: ${p.longitude.toStringAsFixed(6)}'),
        Text('Accuracy:  ${p.accuracy.toStringAsFixed(1)} m'),
        Text('Updated:   $time'),
      ],
    );
  }
}

class _PermissionStatus {
  const _PermissionStatus({required this.ok, this.message});

  final bool ok;
  final String? message;
}
