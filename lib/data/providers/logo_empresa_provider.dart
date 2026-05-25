import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../repositories/settings_repo.dart';
import '../services/logo_empresa_service.dart';

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
