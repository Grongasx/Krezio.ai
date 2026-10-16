import 'dart:async';

import 'package:flutter/material.dart';
import '../../theme/krezio_theme.dart';
import '../../../backend/services/pin_lock.dart';

/// Asks for the PIN (or the fingerprint/face, when on) to open the app.
class LockScreen extends StatefulWidget {
  final PinLock lock;
  final VoidCallback onUnlocked;

  /// Biometric check; null when the device has none or it is off.
  final Future<bool> Function()? biometric;

  const LockScreen({super.key, required this.lock, required this.onUnlocked, this.biometric});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  String? _message;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (widget.biometric != null) WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _tryBiometric() async {
    if (await widget.biometric!()) widget.onUnlocked();
  }

  Future<void> _digit(String d) async {
    if (widget.lock.secondsLeft > 0 || _pin.length >= 6) return;
    setState(() {
      _pin += d;
      _message = null;
    });
    if (_pin.length >= 4) await _submit(auto: true);
  }

  Future<void> _submit({bool auto = false}) async {
    // While typing (4 or 5 digits) a miss isn't counted: the PIN may be longer.
    if (auto && _pin.length < 6) {
      if (await widget.lock.matches(_pin)) widget.onUnlocked();
      return;
    }
    final result = await widget.lock.check(_pin);
    if (result == PinCheck.ok) {
      widget.onUnlocked();
      return;
    }
    setState(() {
      _pin = '';
      if (result == PinCheck.lockedOut) {
        _startCountdown();
      } else {
        _message = 'PIN incorreto. ${widget.lock.triesLeft} ${widget.lock.triesLeft == 1 ? 'tentativa' : 'tentativas'} antes de esperar 30 s.';
      }
    });
  }

  void _startCountdown() {
    _tick?.cancel();
    _message = 'Muitas tentativas. Aguarde ${widget.lock.secondsLeft} s.';
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      final left = widget.lock.secondsLeft;
      setState(() => _message = left > 0 ? 'Muitas tentativas. Aguarde $left s.' : null);
      if (left == 0) t.cancel();
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, IconData? icon}) => SizedBox(
          width: 72,
          height: 72,
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(shape: const CircleBorder()),
            child: icon != null ? Icon(icon) : Text(label, style: const TextStyle(fontSize: KrezioFont.headline)),
          ),
        );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48, color: KrezioColors.aiPurple),
              const SizedBox(height: KrezioSpace.md),
              const Text('Digite seu PIN', style: TextStyle(fontSize: KrezioFont.title, fontWeight: FontWeight.bold)),
              const SizedBox(height: KrezioSpace.lg),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 6; i++)
                    Container(
                      margin: const EdgeInsets.all(6),
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _pin.length ? KrezioColors.aiPurple : Colors.transparent,
                        border: Border.all(color: KrezioColors.aiPurple),
                      ),
                    ),
                ],
              ),
              SizedBox(
                height: 40,
                child: Center(
                  child: Text(_message ?? '', textAlign: TextAlign.center, style: const TextStyle(color: KrezioColors.budgetOver)),
                ),
              ),
              for (final row in const [
                ['1', '2', '3'],
                ['4', '5', '6'],
                ['7', '8', '9'],
              ])
                Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) key(d, onTap: () => _digit(d))]),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  widget.biometric != null ? key('', icon: Icons.fingerprint, onTap: _tryBiometric) : const SizedBox(width: 72),
                  key('0', onTap: () => _digit('0')),
                  key('', icon: Icons.backspace_outlined, onTap: () {
                    if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
                  }),
                ],
              ),
              TextButton(onPressed: _pin.length >= 4 ? () => _submit() : null, child: const Text('OK')),
            ],
          ),
        ),
      ),
    );
  }
}
