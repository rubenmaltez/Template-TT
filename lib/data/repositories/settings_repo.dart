import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import '../models/setting.dart';

class SettingsRepo {
  const SettingsRepo();

  Stream<Map<String, Setting>> watchAll() {
    return ps.db.watch('SELECT * FROM settings ORDER BY categoria, clave').map((rows) {
      final map = <String, Setting>{};
      for (final r in rows) {
        final s = Setting.fromRow(r);
        map[s.clave] = s;
      }
      return map;
    });
  }

  Future<dynamic> read(String clave, {dynamic fallback}) async {
    final rows = await ps.db
        .getAll('SELECT valor FROM settings WHERE clave = ?', [clave]);
    if (rows.isEmpty) return fallback;
    final raw = rows.first['valor'] as String?;
    try {
      return raw == null ? fallback : jsonDecode(raw);
    } catch (_) {
      return raw ?? fallback;
    }
  }

  /// Actualiza el valor de un setting. El valor se serializa con JSON,
  /// así un bool va como `true`, número como `42`, string como `"texto"`.
  Future<void> update(String tenantId, String clave, dynamic valor) async {
    final encoded = jsonEncode(valor);
    final now = DateTime.now().toIso8601String();
    await ps.db.execute(
      'UPDATE settings SET valor = ?, updated_at = ? WHERE tenant_id = ? AND clave = ?',
      [encoded, now, tenantId, clave],
    );
  }
}

final settingsRepoProvider = Provider((_) => const SettingsRepo());

/// Mapa clave→Setting. Único stream global de settings.
final settingsMapProvider = StreamProvider<Map<String, Setting>>((ref) {
  return ref.watch(settingsRepoProvider).watchAll();
});

/// Helper genérico tipado: lee un setting con default.
T settingValue<T>(Map<String, Setting>? map, String clave, T fallback) {
  if (map == null) return fallback;
  final s = map[clave];
  if (s == null) return fallback;
  final v = s.valor;
  if (v is T) return v;
  if (T == double && v is num) return v.toDouble() as T;
  if (T == int && v is num) return v.toInt() as T;
  return fallback;
}

/// Acceso tipado a los settings más usados en la app.
class AppSettings {
  AppSettings(this._map);
  final Map<String, Setting>? _map;

  int get diasGracia => settingValue<num>(_map, 'cobranza.dias_gracia', 10).toInt();
  bool get descuentosHabilitados =>
      settingValue<bool>(_map, 'cobranza.descuentos_habilitados', false);
  String get descuentoTipo =>
      settingValue<String>(_map, 'cobranza.descuento_tipo', 'monto');
  double get descuentoMaxMonto =>
      settingValue<num>(_map, 'cobranza.descuento_max_monto', 0).toDouble();
  double get descuentoMaxPorcentaje =>
      settingValue<num>(_map, 'cobranza.descuento_max_porcentaje', 0).toDouble();

  bool get reconexionHabilitada =>
      settingValue<bool>(_map, 'cobranza.cargo_reconexion_habilitado', false);
  double get montoReconexion =>
      settingValue<num>(_map, 'cobranza.monto_reconexion', 0).toDouble();

  bool get transferenciaHabilitada =>
      settingValue<bool>(_map, 'pagos.transferencia_habilitada', false);
  bool get depositoHabilitado =>
      settingValue<bool>(_map, 'pagos.deposito_habilitado', false);
  bool get tarjetaHabilitada =>
      settingValue<bool>(_map, 'pagos.tarjeta_habilitada', false);
  bool get usdHabilitado =>
      settingValue<bool>(_map, 'pagos.usd_habilitado', true);
  double get tasaUsd =>
      settingValue<num>(_map, 'pagos.tasa_usd_cordoba', 36.5).toDouble();

  int get formatoReciboMm =>
      settingValue<num>(_map, 'recibo.formato_default_mm', 80).toInt();
  String get pieRecibo => settingValue<String>(_map, 'recibo.pie_libre', '');

  String get empresaNombre => settingValue<String>(_map, 'empresa.nombre', '');
  String get empresaDireccion =>
      settingValue<String>(_map, 'empresa.direccion', '');
  String get empresaTelefono =>
      settingValue<String>(_map, 'empresa.telefono', '');
  String get empresaRuc => settingValue<String>(_map, 'empresa.ruc', '');

  /// Path del logo en Storage (bucket `logos-empresa`). Vacío si no hay logo.
  String get empresaLogoPath =>
      settingValue<String>(_map, 'empresa.logo_path', '');

  /// Si el recibo debe incluir el logo (toggle en tab Recibos).
  bool get imprimirLogoEnRecibo =>
      settingValue<bool>(_map, 'recibo.imprimir_logo', true);
}

final appSettingsProvider = Provider<AppSettings>((ref) {
  final map = ref.watch(settingsMapProvider).valueOrNull;
  return AppSettings(map);
});
