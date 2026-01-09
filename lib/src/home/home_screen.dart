import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

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

  bool _permissionDialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _primeLocationGate();
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  Future<void> _primeLocationGate() async {
    final shouldShow = await _shouldShowLocationDialog();
    if (!mounted) return;

    if (!shouldShow) {
      await _startLocationTracking();
      return;
    }

    await _showLocationAccessDialog();
  }

  Future<void> _showLocationAccessDialog() async {
    if (!mounted) return;
    if (_permissionDialogOpen) return;

    _permissionDialogOpen = true;
    try {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierLabel: 'Location permission required',
        pageBuilder: (routeContext, animation, secondaryAnimation) {
          var busy = false;

          return PopScope(
            canPop: false,
            child: SafeArea(
              child: Center(
                child: StatefulBuilder(
                  builder: (dialogContext, setDialogState) {
                    Future<void> onAllow() async {
                      if (busy) return;
                      setDialogState(() => busy = true);

                      try {
                        if (kIsWeb) return;

                        final enabled =
                            await Geolocator.isLocationServiceEnabled();
                        if (!enabled) {
                          await Geolocator.openLocationSettings();
                        }

                        final permission = Platform.isIOS
                            ? Permission.locationWhenInUse
                            : Permission.location;

                        var status = await permission.status;
                        if (status.isDenied ||
                            status.isRestricted ||
                            status.isLimited) {
                          status = await permission.request();
                        }

                        if (status.isPermanentlyDenied) {
                          await Geolocator.openAppSettings();
                        }

                        final shouldShow =
                            await _shouldShowLocationDialog();
                        if (!shouldShow) {
                          if (!dialogContext.mounted) return;
                          Navigator.of(dialogContext).pop();
                          await _startLocationTracking();
                        }
                      } finally {
                        if (dialogContext.mounted) {
                          setDialogState(() => busy = false);
                        }
                      }
                    }

                    Future<void> onLogout() async {
                      if (busy) return;

                      final confirmed = await _confirmSignOut(dialogContext);
                      if (!confirmed) return;

                      setDialogState(() => busy = true);
                      try {
                        await _logout();
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                      } finally {
                        if (dialogContext.mounted) {
                          setDialogState(() => busy = false);
                        }
                      }
                    }

                    return ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Dialog(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 420),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    'Please allow Location access to get access to app functions.',
                                    style: Theme.of(dialogContext)
                                        .textTheme
                                        .titleMedium,
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 16),
                                  FilledButton(
                                    onPressed: busy ? null : onAllow,
                                    child: busy
                                        ? const SizedBox(
                                            height: 18,
                                            width: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Text('Allow location access'),
                                  ),
                                  const SizedBox(height: 10),
                                  OutlinedButton.icon(
                                    onPressed: busy ? null : onLogout,
                                    icon: const Icon(Icons.logout),
                                    label: const Text('Logout'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      );
    } finally {
      _permissionDialogOpen = false;
    }
  }

  Future<bool> _shouldShowLocationDialog() async {
    if (kIsWeb) return false;

    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return true;

    final permission = Platform.isIOS
        ? Permission.locationWhenInUse
        : Permission.location;

    final status = await permission.status;
    return !status.isGranted;
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

        await _showLocationAccessDialog();
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

  Future<void> _logout() async {
    await AuthService(FirebaseAuth.instance).signOut();
  }

  Future<bool> _confirmSignOut(BuildContext dialogContext) async {
    final result = await showDialog<bool>(
      context: dialogContext,
      builder: (context) {
        return AlertDialog(
          title: const Text('Sign out?'),
          content: const Text('Are you sure you want to sign out?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Sign out'),
            ),
          ],
        );
      },
    );

    return result ?? false;
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

  List<fm.Marker> _markers(BuildContext context) {
    final pos = _position;
    if (pos == null) return const [];

    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
        );

    return [
      fm.Marker(
        point: LatLng(pos.latitude, pos.longitude),
        width: 64,
        height: 72,
        alignment: Alignment.topCenter,
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('YOU', style: labelStyle),
              const Icon(
                Icons.location_pin,
                size: 42,
                color: Colors.red,
              ),
            ],
          ),
        ),
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
              final confirmed = await _confirmSignOut(context);
              if (!confirmed) return;
              await _logout();
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
                    onPressed: _requesting ? null : _primeLocationGate,
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
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.live_tracker',
                  ),
                  fm.MarkerLayer(markers: _markers(context)),
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
     Row (
      
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [ Text('Latitude:  ${p.latitude.toStringAsFixed(6)}'),
        Text('Longitude: ${p.longitude.toStringAsFixed(6)}'),]),

        Row(   mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Accuracy:  ${p.accuracy.toStringAsFixed(1)} m'),
            Text('Updated:   $time'),
          ],
        ),
      ],
    );
  }
}

class _PermissionStatus {
  const _PermissionStatus({required this.ok, this.message});

  final bool ok;
  final String? message;
}
