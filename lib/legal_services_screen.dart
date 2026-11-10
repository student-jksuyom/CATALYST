import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import 'map_preview.dart';

enum LegalServiceType {
  publicAttorney('Public Attorney\'s Office', 'Public Attorney\'s Office'),
  lawyers('Lawyers and Law Offices', 'lawyers and law offices'),
  legalAid('Legal aid services', 'legal aid services');

  const LegalServiceType(this.label, this.query);

  final String label;
  final String query;
}

class SearchLocation {
  const SearchLocation(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

class LocationSearchException implements Exception {
  const LocationSearchException(this.message);

  final String message;
}

Future<SearchLocation> getSearchLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const LocationSearchException(
      'Location services are off. Turn them on or search by city instead.',
    );
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied) {
    throw const LocationSearchException(
      'Location permission was denied. You can search by city instead.',
    );
  }
  if (permission == LocationPermission.deniedForever) {
    throw const LocationSearchException(
      'Location permission is blocked. Change it in device settings or search by city instead.',
    );
  }
  if (permission == LocationPermission.unableToDetermine) {
    throw const LocationSearchException(
      'Location permission could not be determined. Search by city instead.',
    );
  }

  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.low,
      timeLimit: Duration(seconds: 20),
    ),
  );
  return SearchLocation(position.latitude, position.longitude);
}

Uri legalServicesSearchUri(LegalServiceType type, String location) {
  return Uri.https('www.google.com', '/maps/search/', {
    'api': '1',
    'query': '${type.query} near $location',
  });
}

Uri androidLegalServicesSearchUri(
  LegalServiceType type,
  SearchLocation location,
) {
  final coordinates =
      '${location.latitude.toStringAsFixed(3)},'
      '${location.longitude.toStringAsFixed(3)}';
  return Uri(
    scheme: 'geo',
    path: coordinates,
    queryParameters: {'q': type.query},
  );
}

class LegalServicesScreen extends StatefulWidget {
  const LegalServicesScreen({
    super.key,
    this.locate = getSearchLocation,
    this.openMap = _openGoogleMaps,
    this.preview,
  });

  final Future<SearchLocation> Function() locate;
  final Future<bool> Function(Uri uri) openMap;
  final Widget? preview;

  @override
  State<LegalServicesScreen> createState() => _LegalServicesScreenState();
}

Future<bool> _openGoogleMaps(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

class _LegalServicesScreenState extends State<LegalServicesScreen> {
  final _cityController = TextEditingController();
  var _selected = LegalServiceType.publicAttorney;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _cityController.dispose();
    super.dispose();
  }

  Future<void> _search({required bool useLocation}) async {
    if (_busy) return;
    final city = _cityController.text.trim();
    if (!useLocation && city.isEmpty) {
      setState(() => _error = 'Enter a city or municipality to search.');
      return;
    }

    final selected = _selected;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var area = city;
      SearchLocation? location;
      if (useLocation) {
        location = await widget.locate();
        area =
            '${location.latitude.toStringAsFixed(3)},'
            '${location.longitude.toStringAsFixed(3)}';
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Open Google Maps?'),
          content: const Text(
            'You are about to leave CATALYST to view search results in a map app or browser.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Open Google Maps'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      var launched = false;
      if (location != null && defaultTargetPlatform == TargetPlatform.android) {
        try {
          launched = await widget.openMap(
            androidLegalServicesSearchUri(selected, location),
          );
        } on PlatformException catch (error, stackTrace) {
          developer.log(
            'Map intent failed (${error.code}); trying a Google Maps URL',
            name: 'catol.legal_services',
            stackTrace: stackTrace,
          );
        }
      }
      if (!launched && mounted) {
        launched = await widget.openMap(legalServicesSearchUri(selected, area));
      }
      if (!launched && mounted) {
        setState(() => _error = 'Could not open Google Maps or a browser.');
      }
    } on LocationSearchException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stackTrace) {
      developer.log(
        'Legal services search failed (${error.runtimeType})',
        name: 'catol.legal_services',
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(
          () => _error = 'Could not complete the search. Check location and internet settings, or search by city.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Find Legal Services')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Find legal help near you',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: const Color(0xFF1A307F),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Choose a service and a location. Results open outside CATALYST in Google Maps or a browser.',
            ),
            const SizedBox(height: 20),
            Text('Map', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Explore this fixed-area Google Maps preview. It does not show your location or legal service search results.',
            ),
            const SizedBox(height: 12),
            SizedBox(
              key: const ValueKey('legal-services-map-preview'),
              height: 400,
              child: widget.preview ?? const MapPreview(),
            ),
            const SizedBox(height: 24),
            Text('Choose a service', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final type in LegalServiceType.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ChoiceChip(
                  label: Text(type.label),
                  selected: _selected == type,
                  onSelected: _busy
                      ? null
                      : (_) => setState(() => _selected = type),
                ),
              ),
            const SizedBox(height: 16),
            const Text(
              'Searching with your location sends approximate coordinates to the map app or Google Maps. CATALYST does not save it.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : () => _search(useLocation: true),
              icon: const Icon(Icons.my_location),
              label: Text(
                _busy ? 'Preparing search...' : 'Search using my location',
              ),
            ),
            const SizedBox(height: 24),
            Text('Or search by city', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _cityController,
              enabled: !_busy,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(useLocation: false),
              decoration: const InputDecoration(
                labelText: 'City or municipality',
                hintText: 'e.g., Calamba, Laguna',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _search(useLocation: false),
              icon: const Icon(Icons.search),
              label: const Text('Search this area in Google Maps'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                key: const ValueKey('legal-services-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            const Text(
              'Internet is required. Google Maps results may be incomplete or out of date; verify contact details and credentials.',
            ),
          ],
        ),
      ),
    );
  }
}
