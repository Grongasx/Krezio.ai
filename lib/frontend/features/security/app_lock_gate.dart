import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../theme/krezio_theme.dart';
import '../../../backend/services/pin_lock.dart';
import 'lock_screen.dart';

/// Wraps the app: asks for the PIN when it opens and when it comes back
/// after [PinLock.autoLockAfter] in the background, and covers the content
/// while the app is not in front, so no value shows in the recent-apps view.
class AppLockGate extends StatefulWidget {
  final PinLock lock;
  final Widget child;
  final Future<bool> Function()? biometric;

  const AppLockGate({super.key, required this.lock, required this.child, this.biometric});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _locked = false;
  bool _covered = false;
  bool _checked = false;
  bool _useBiometric = false;
  DateTime? _backgroundSince;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialCheck();
  }

  Future<void> _initialCheck() async {
    final enabled = await widget.lock.isEnabled;
    final bio = widget.biometric != null && await widget.lock.biometricsEnabled;
    if (!mounted) return;
    setState(() {
      _locked = enabled;
      _useBiometric = bio;
      _checked = true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _backgroundSince ??= DateTime.now();
        // Only with the PIN on — and on the web/desktop not for a mere loss
        // of focus ("inactive"), which covered the app at every click outside.
        final cover = !kIsWeb && defaultTargetPlatform != TargetPlatform.windows || state != AppLifecycleState.inactive;
        widget.lock.isEnabled.then((on) {
          if (on && cover && mounted && _backgroundSince != null && !_covered) setState(() => _covered = true);
        });
      case AppLifecycleState.resumed:
        final since = _backgroundSince;
        _backgroundSince = null;
        widget.lock.shouldLockOnResume(since).then((lock) async {
          final bio = widget.biometric != null && await widget.lock.biometricsEnabled;
          if (!mounted) return;
          setState(() {
            _covered = false;
            _useBiometric = bio;
            if (lock) _locked = true;
          });
        });
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) return const Scaffold(body: SizedBox.shrink());
    if (_locked) {
      return LockScreen(
        lock: widget.lock,
        biometric: _useBiometric ? widget.biometric : null,
        onUnlocked: () => setState(() => _locked = false),
      );
    }
    return Stack(
      children: [
        widget.child,
        if (_covered)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: const Center(child: Icon(Icons.lock_outline, size: 48, color: KrezioColors.aiPurple)),
            ),
          ),
      ],
    );
  }
}
