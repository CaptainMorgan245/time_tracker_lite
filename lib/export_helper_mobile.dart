import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<void> exportFile(String filename, String content, String mimeType) async {
  final directory = await getTemporaryDirectory();
  final path = '${directory.path}/$filename';
  final file = File(path);
  await file.writeAsString(content);
  await Share.shareXFiles([XFile(path, mimeType: mimeType)], subject: filename);
}
