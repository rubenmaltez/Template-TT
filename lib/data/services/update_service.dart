import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../config/env.dart';

/// Información de una actualización disponible.
class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.downloadUrl,
    this.releaseNotes,
  });

  final String version;
  final String downloadUrl;
  final String? releaseNotes;
}

/// Servicio que checa si hay una versión más nueva de la app disponible.
///
/// Lee un archivo `version.json` hosteado en Supabase Storage (bucket
/// público `installers`). Formato esperado:
///
/// ```json
/// {
///   "version": "1.1.0",
///   "download_url": "https://.../cobranza-isp-1.1.0.msix",
///   "release_notes": "Mejora en reportes + fix de sync"
/// }
/// ```
///
/// Compara con la versión local (`package_info_plus`) y retorna
/// `AppUpdate` si hay nueva versión, `null` si está al día.
class UpdateService {
  /// URL del version.json. Construida a partir del Supabase URL del
  /// proyecto + path al bucket público `installers`.
  static String get _versionUrl =>
      '${Env.supabaseUrl}/storage/v1/object/public/installers/version.json';

  /// Checa si hay actualización disponible. Retorna null si está al día
  /// o si no se puede conectar (no bloquea el arranque).
  static Future<AppUpdate?> checkForUpdate() async {
    try {
      final response = await http
          .get(Uri.parse(_versionUrl))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final remoteVersion = json['version'] as String?;

      // URL por plataforma: version.json tiene download_url_windows,
      // download_url_android, y download_url como fallback genérico.
      // Formato esperado:
      // {
      //   "version": "0.2.0",
      //   "download_url_windows": "https://.../cobranza-isp-0.2.0.msix",
      //   "download_url_android": "https://.../cobranza-isp-0.2.0.apk",
      //   "download_url": "https://.../fallback",
      //   "release_notes": "..."
      // }
      final platformKey = kIsWeb
          ? 'download_url'
          : Platform.isAndroid
              ? 'download_url_android'
              : Platform.isWindows
                  ? 'download_url_windows'
                  : 'download_url';
      final downloadUrl =
          json[platformKey] as String? ?? json['download_url'] as String?;

      if (remoteVersion == null || downloadUrl == null) return null;

      final packageInfo = await PackageInfo.fromPlatform();
      final localVersion = packageInfo.version;

      if (_isNewer(remoteVersion, localVersion)) {
        return AppUpdate(
          version: remoteVersion,
          downloadUrl: downloadUrl,
          releaseNotes: json['release_notes'] as String?,
        );
      }

      return null;
    } catch (e) {
      debugPrint('[UPDATE] Check failed (non-blocking): $e');
      return null;
    }
  }

  /// Comparación semver simplificada: "1.2.0" > "1.1.0".
  /// Soporta major.minor.patch. Si el formato es inválido, retorna false.
  static bool _isNewer(String remote, String local) {
    final r = remote.split('.').map(int.tryParse).toList();
    final l = local.split('.').map(int.tryParse).toList();

    if (r.length < 3 || l.length < 3) return false;
    if (r.any((n) => n == null) || l.any((n) => n == null)) return false;

    for (var i = 0; i < 3; i++) {
      if (r[i]! > l[i]!) return true;
      if (r[i]! < l[i]!) return false;
    }
    return false;
  }
}
