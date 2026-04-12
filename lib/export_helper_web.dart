import 'dart:js_interop';
import 'package:web/web.dart';

Future<void> exportFile(String filename, String content, String mimeType) async {
  final blob = Blob([content.toJS].toJS, BlobPropertyBag(type: mimeType));
  final url = URL.createObjectURL(blob);
  final anchor = document.createElement('a') as HTMLAnchorElement;
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  URL.revokeObjectURL(url);
}
