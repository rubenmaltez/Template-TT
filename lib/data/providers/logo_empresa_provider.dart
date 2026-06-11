import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../repositories/settings_repo.dart';
import '../services/logo_cache_service.dart';
import '../services/logo_empresa_service.dart';
import 'cobrador_provider.dart';

/// Servicio singleton de logo (usa el SupabaseClient global).
final logoEmpresaServiceProvider = Provider<LogoEmpresaService>((ref) {
  return LogoEmpresaService(Supabase.instance.client);
});

/// URL firmada del logo de la empresa. Se refresca cuando cambia
/// `empresa.logo_path` en settings (reactivo vía settingsMapProvider).
///
/// Retorna null si no hay logo configurado o si la firma falla.
/// TTL de la URL: 1h (el provider se invalida antes si el setting cambia).
final logoEmpresaUrlProvider = FutureProvider<String?>((ref) async {
  final settings = ref.watch(appSettingsProvider);
  final path = settings.empresaLogoPath;

  if (path.isEmpty) return null;

  final service = ref.read(logoEmpresaServiceProvider);
  return service.urlFirmada(path);
});

/// BYTES del logo de la empresa (PNG/JPG) o null si no hay logo.
///
/// Es la fuente del logo para `ReciboTicket` (preview + impresión térmica) —
/// el widget se captura a imagen offline, así que necesita BYTES, no una URL.
///
/// Estrategia OFFLINE-first:
///   1. Cache local (`leerLogoCacheado`): si el logo ya se descargó alguna vez,
///      sirve sin red (clave para imprimir en campo sin conexión).
///   2. Fallback online: si no hay cache pero hay `logo_path` configurado y red,
///      descarga del bucket y refresca el cache para próximas impresiones.
///
/// Reactivo: se refresca cuando cambia `empresa.logo_path` en settings.
final logoEmpresaBytesProvider = FutureProvider<Uint8List?>((ref) async {
  final settings = ref.watch(appSettingsProvider);
  final path = settings.empresaLogoPath;
  if (path.isEmpty) return null;

  final tenantId = ref.watch(tenantIdProvider);
  final cache = LogoCacheService();

  // 1) Cache local (offline).
  if (tenantId != null) {
    final cached = await cache.leerLogoCacheado(tenantId);
    if (cached != null && cached.isNotEmpty) return cached;
  }

  // 2) Fallback online: bajar del bucket y refrescar el cache local.
  try {
    final bytes = await Supabase.instance.client.storage
        .from('logos-empresa')
        .download(path);
    if (bytes.isEmpty) return null;
    if (tenantId != null) {
      await cache.refrescarLogo(tenantId: tenantId, logoPath: path);
    }
    return bytes;
  } catch (e) {
    if (kDebugMode) debugPrint('logoEmpresaBytesProvider: $e');
    return null;
  }
});
