import 'package:shared_preferences/shared_preferences.dart';
import 'pin_lock.dart';

/// [PinStore] on the device's local storage. Kept apart from the synced data:
/// the PIN's hash never goes to the cloud.
class PrefsPinStore implements PinStore {
  static const _prefix = 'krezio_lock_';

  @override
  Future<String?> read(String key) async => (await SharedPreferences.getInstance()).getString('$_prefix$key');

  @override
  Future<void> write(String key, String? value) async {
    final p = await SharedPreferences.getInstance();
    value == null ? await p.remove('$_prefix$key') : await p.setString('$_prefix$key', value);
  }
}
