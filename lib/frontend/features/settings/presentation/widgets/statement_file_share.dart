import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

Future<String?> exportStatementFile(String name, Uint8List bytes) async {
  final result = await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(bytes, mimeType: 'text/csv')],
      fileNameOverrides: [name],
    ),
  );
  return result.status == ShareResultStatus.success
      ? 'Extrato compartilhado.'
      : null;
}
