// Minimal reproduction: on iOS, the first ad request issued after the UMP
// `requestConsentInfoUpdate` callback carries no TCF signals in Ad Inspector,
// while a request issued ~1 s later carries them all.
//
// Everything here uses Google's sample app ID and test ad units only.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Paste the hashed device id that the UMP SDK prints in the Xcode console on
/// first run ("To enable debug mode for this device, set: testDeviceIdentifiers
/// = @[ @"XXXXXXXX" ]"). The iOS simulator is usually accepted without it.
const List<String> kUmpTestDeviceIds = <String>[];

/// Google's App Open test ad unit (iOS).
const String kAppOpenTestUnit = 'ca-app-pub-3940256099942544/5575463023';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ReproApp());
}

class ReproApp extends StatelessWidget {
  const ReproApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'UMP TCF repro',
      home: ReproPage(),
    );
  }
}

enum Loader { preloader, appOpenLoad }

class ReproPage extends StatefulWidget {
  const ReproPage({super.key});

  @override
  State<ReproPage> createState() => _ReproPageState();
}

class _ReproPageState extends State<ReproPage> {
  final List<String> _lines = <String>[];
  final ScrollController _scroll = ScrollController();
  Loader _loader = Loader.preloader;
  int _delayMs = 0;
  bool _busy = false;
  bool _sdkInitialized = false;
  Timer? _keyMonitor;
  String? _lastKeys;

  static const String _preloadId = 'repro_app_open';

  // ─── Logging ─────────────────────────────────────────────────────────────

  void _log(String message) {
    final now = DateTime.now();
    final stamp = now.toIso8601String().substring(11, 23);
    final line = '$stamp  $message';
    debugPrint('[repro] $line');
    if (!mounted) return;
    setState(() => _lines.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // ─── IABTCF keys, read from UserDefaults.standard (what the GMA SDK reads) ──

  Future<T?> _read<T>(Future<T?> Function() read) async {
    try {
      return await read();
    } catch (e) {
      return null;
    }
  }

  Future<String> _describeKeys() async {
    final prefs = SharedPreferencesAsync();
    final gdpr = await _read(() => prefs.getInt('IABTCF_gdprApplies'));
    final tc = await _read(() => prefs.getString('IABTCF_TCString'));
    final ac = await _read(() => prefs.getString('IABTCF_AddtlConsent'));
    final policy = await _read(() => prefs.getInt('IABTCF_PolicyVersion'));
    if (gdpr == null && tc == null && ac == null && policy == null) {
      return 'no IABTCF keys';
    }
    return 'gdprApplies=${gdpr ?? '-'} '
        'TCString=${tc == null || tc.isEmpty ? 'absent' : '${tc.length} chars'} '
        'AddtlConsent=${ac == null || ac.isEmpty ? 'absent' : '${ac.length} chars'} '
        'PolicyVersion=${policy ?? '-'}';
  }

  /// Logs every change of the IABTCF keys for 5 s after the UMP callback.
  void _startKeyMonitor() {
    _keyMonitor?.cancel();
    final startedAt = DateTime.now();
    _keyMonitor = Timer.periodic(const Duration(milliseconds: 100), (t) async {
      final keys = await _describeKeys();
      if (keys != _lastKeys) {
        _lastKeys = keys;
        final ms = DateTime.now().difference(startedAt).inMilliseconds;
        _log('keys changed (+$ms ms after UMP callback): $keys');
      }
      if (DateTime.now().difference(startedAt) > const Duration(seconds: 5)) {
        t.cancel();
      }
    });
  }

  // ─── The sequence under test ──────────────────────────────────────────────

  Future<void> _runSequence() async {
    if (_busy) return;
    setState(() => _busy = true);
    _log('── sequence: loader=${_loader.name}, delay after init=$_delayMs ms');
    _log('keys before requestConsentInfoUpdate: ${await _describeKeys()}');

    final completer = Completer<void>();
    final startedAt = DateTime.now();
    final params = ConsentRequestParameters(
      consentDebugSettings: ConsentDebugSettings(
        debugGeography: DebugGeography.debugGeographyEea,
        testIdentifiers: kUmpTestDeviceIds,
      ),
    );

    ConsentInformation.instance.requestConsentInfoUpdate(
      params,
      () async {
        final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
        final status = await ConsentInformation.instance.getConsentStatus();
        _lastKeys = await _describeKeys();
        _log('UMP callback after $elapsed ms, status=${status.name}, '
            'keys: $_lastKeys');
        _startKeyMonitor();
        try {
          if (await ConsentInformation.instance.isConsentFormAvailable()) {
            _log('consent form available → loadAndShowConsentFormIfRequired');
            await ConsentForm.loadAndShowConsentFormIfRequired((error) {
              if (error != null) {
                _log('form error: ${error.errorCode} ${error.message}');
              }
            });
            final after = await ConsentInformation.instance.getConsentStatus();
            _log('form step done, status=${after.name}, '
                'keys: ${await _describeKeys()}');
          }
          final canRequest = await ConsentInformation.instance.canRequestAds();
          _log('canRequestAds=$canRequest');
          if (!canRequest) {
            completer.complete();
            return;
          }
          if (!_sdkInitialized) {
            final initAt = DateTime.now();
            await MobileAds.instance.initialize();
            _sdkInitialized = true;
            _log('MobileAds.initialize done in '
                '${DateTime.now().difference(initAt).inMilliseconds} ms, '
                'keys: ${await _describeKeys()}');
          }
          if (_delayMs > 0) {
            await Future<void>.delayed(Duration(milliseconds: _delayMs));
          }
          _log('→ requesting ad now, keys: ${await _describeKeys()}');
          await _loadAd();
        } catch (e) {
          _log('error: $e');
        }
        completer.complete();
      },
      (error) {
        _log('UMP update failed: ${error.errorCode} ${error.message}');
        completer.complete();
      },
    );

    await completer.future;
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _loadAd() async {
    final requestedAt = DateTime.now();
    String since() =>
        '${DateTime.now().difference(requestedAt).inMilliseconds} ms';
    switch (_loader) {
      case Loader.preloader:
        await AppOpenAdPreloader.destroy(_preloadId);
        await AppOpenAdPreloader.start(
          preloadId: _preloadId,
          preloadConfiguration: const PreloadConfiguration(
            adUnitId: kAppOpenTestUnit,
            request: AdRequest(),
            bufferSize: 1,
          ),
          callback: PreloadCallback(
            onAdPreloaded: (id, info) =>
                _log('preloaded after ${since()} (${info.responseId})'),
            onAdsExhausted: (id) => _log('preloader exhausted'),
            onAdFailedToPreload: (id, error) =>
                _log('preload failed after ${since()}: ${error.message}'),
          ),
        );
        _log('AppOpenAdPreloader.start returned');
      case Loader.appOpenLoad:
        await AppOpenAd.load(
          adUnitId: kAppOpenTestUnit,
          request: const AdRequest(),
          adLoadCallback: AppOpenAdLoadCallback(
            onAdLoaded: (ad) {
              _log('AppOpenAd loaded after ${since()} '
                  '(${ad.responseInfo?.responseId})');
              ad.dispose();
            },
            onAdFailedToLoad: (error) =>
                _log('AppOpenAd failed after ${since()}: ${error.message}'),
          ),
        );
        _log('AppOpenAd.load returned');
    }
  }

  /// Consumes the preloaded ad so that the SDK issues its refill request:
  /// that second request is the one that carries the TCF signals on device.
  Future<void> _poll() async {
    final ad = await AppOpenAdPreloader.pollAd(_preloadId);
    _log(ad == null
        ? 'pollAd: nothing available'
        : 'pollAd: got ${ad.responseInfo?.responseId} → SDK refills now');
    ad?.dispose();
  }

  Future<void> _resetConsent() async {
    _keyMonitor?.cancel();
    ConsentInformation.instance.reset();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _log('consent reset, keys: ${await _describeKeys()}');
  }

  void _openInspector() {
    MobileAds.instance.openAdInspector((error) {
      if (error != null) {
        _log('inspector error: ${error.code} ${error.message}');
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _describeKeys().then((keys) => _log('app start, keys: $keys'));
  }

  @override
  void dispose() {
    _keyMonitor?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // ─── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UMP → first ad request (TCF)')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<Loader>(
                  segments: const [
                    ButtonSegment(
                        value: Loader.preloader, label: Text('Preloader')),
                    ButtonSegment(
                        value: Loader.appOpenLoad,
                        label: Text('AppOpenAd.load')),
                  ],
                  selected: {_loader},
                  onSelectionChanged: (s) => setState(() => _loader = s.first),
                ),
                DropdownButton<int>(
                  value: _delayMs,
                  items: const [0, 300, 1000, 2000]
                      .map((ms) => DropdownMenuItem(
                          value: ms, child: Text('delay $ms ms')))
                      .toList(),
                  onChanged: (v) => setState(() => _delayMs = v ?? 0),
                ),
                FilledButton(
                  onPressed: _busy ? null : _runSequence,
                  child: const Text('Run sequence'),
                ),
                OutlinedButton(
                  onPressed: _poll,
                  child: const Text('pollAd (refill)'),
                ),
                OutlinedButton(
                  onPressed: _openInspector,
                  child: const Text('Ad Inspector'),
                ),
                OutlinedButton(
                  onPressed: _resetConsent,
                  child: const Text('Reset consent'),
                ),
                TextButton(
                  onPressed: () => setState(_lines.clear),
                  child: const Text('Clear log'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(8),
              itemCount: _lines.length,
              itemBuilder: (_, i) => SelectableText(
                _lines[i],
                style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
