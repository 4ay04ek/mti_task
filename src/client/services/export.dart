import 'dart:typed_data';
import 'dart:ui';

import 'package:share_plus/share_plus.dart';

Future<void> saveCsv(Uint8List bytes, Rect origin) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(bytes, mimeType: 'text/csv', name: 'tickets.csv')],
      fileNameOverrides: ['tickets.csv'],
      sharePositionOrigin: origin,
    ),
  );
}
