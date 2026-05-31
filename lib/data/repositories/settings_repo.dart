import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

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

  /// Upsert de un setting: actualiza si la fila existe, la inserta si no.
  ///
  /// No usamos `ON CONFLICT(tenant_id, clave)` porque la constraint UNIQUE
  /// vive en Postgres, pero la tabla local de PowerSync solo enforcea el PK
  /// `id`. Por eso hacemos SELECT → UPDATE | INSERT (ambos válidos en SQLite).
  ///
  /// `valor` se serializa con JSON. `tipo`/`categoria` se respetan al crear.
  Future<void> upsert(
    String tenantId,
    String clave,
    dynamic valor, {
    String tipo = 'json',
    String categoria = 'cobranza',
  }) async {
    final encoded = jsonEncode(valor);
    final now = DateTime.now().toIso8601String();

    final existentes = await ps.db.getAll(
      'SELECT id FROM settings WHERE tenant_id = ? AND clave = ? LIMIT 1',
      [tenantId, clave],
    );

    if (existentes.isNotEmpty) {
      await ps.db.execute(
        'UPDATE settings SET valor = ?, updated_at = ? WHERE tenant_id = ? AND clave = ?',
        [encoded, now, tenantId, clave],
      );
      return;
    }

    // INSERT: incluir todas las columnas NOT NULL (tenant_id, clave, valor,
    // tipo, categoria) + id (PK local de PowerSync) + updated_at.
    await ps.db.execute(
      '''
      INSERT INTO settings (id, tenant_id, clave, valor, tipo, categoria, editable_por, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        const Uuid().v4(),
        tenantId,
        clave,
        encoded,
        tipo,
        categoria,
        'admin',
        now,
      ],
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
  // Boolean defense: JSONB puede llegar como string "true"/"false" via PowerSync.
  if (T == bool && v is String) {
    return (v.toLowerCase() == 'true') as T;
  }
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

  // Efectivo: la migración 0040 introdujo `pagos.metodo_efectivo` que
  // permite al admin deshabilitar efectivo. Default true (siempre visible
  // a menos que el admin lo apague explícitamente).
  bool get efectivoHabilitado =>
      settingValue<bool>(_map, 'pagos.metodo_efectivo', true);

  // Transferencia: chequeamos la clave original de 0010 y la de 0040 (OR).
  // Esto cubre tenants que tengan una, la otra, o ambas.
  bool get transferenciaHabilitada =>
      settingValue<bool>(_map, 'pagos.transferencia_habilitada', false) ||
      settingValue<bool>(_map, 'pagos.metodo_transferencia', false);
  bool get depositoHabilitado =>
      settingValue<bool>(_map, 'pagos.deposito_habilitado', false);
  // Tarjeta: chequeamos clave original de 0010 y la de 0040 (OR).
  bool get tarjetaHabilitada =>
      settingValue<bool>(_map, 'pagos.tarjeta_habilitada', false) ||
      settingValue<bool>(_map, 'pagos.metodo_tarjeta', false);
  bool get usdHabilitado =>
      settingValue<bool>(_map, 'pagos.usd_habilitado', true);
  double get tasaUsd =>
      settingValue<num>(_map, 'pagos.tasa_usd_cordoba', 36.5).toDouble();

  // Cuotas: permisos del admin.
  bool get cuotasManuales =>
      settingValue<bool>(_map, 'cuotas.manuales', false);
  bool get cuotasEditarMonto =>
      settingValue<bool>(_map, 'cuotas.editar_monto', false);

  // Permisos del cobrador (toggles en Settings → Cobranza).
  bool get cobradorEditaFecha =>
      settingValue<bool>(_map, 'cobranza.cobrador_edita_fecha', false);
  bool get cobradorAnulaCobros =>
      settingValue<bool>(_map, 'cobranza.cobrador_anula_cobros', false);
  bool get cobradorEditaCobros =>
      settingValue<bool>(_map, 'cobranza.cobrador_edita_cobros', false);
  bool get fotoObligatoria =>
      settingValue<bool>(_map, 'cobranza.foto_obligatoria', false);
  bool get pagoParcialPermitido =>
      settingValue<bool>(_map, 'cobranza.pago_parcial', true);
  bool get pagoAdelantadoPermitido =>
      settingValue<bool>(_map, 'cobranza.pago_adelantado', true);

  int get diasCuotasVisibles =>
      settingValue<num>(_map, 'cobranza.dias_cuotas_visibles', 30).toInt();

  /// Valor del descuento pronto pago. 0 = deshabilitado.
  double get descuentoProntoPago =>
      settingValue<num>(_map, 'cuotas.descuento_pronto_pago', 0).toDouble();

  /// Tipo de descuento: 'porcentaje' o 'monto'.
  String get descuentoProntoPagoTipo =>
      settingValue<String>(_map, 'cuotas.descuento_pronto_pago_tipo', 'porcentaje');

  /// Feature flag: gestión de caja chica del cobrador (asignación diaria
  /// y reconciliación de efectivo al cierre). Default false. Migración 0063
  /// agrega el toggle; la feature real (tabla cajas_chicas + UI) está
  /// pendiente — usar este getter cuando se implemente para gatear la UI.
  bool get cajaChicaHabilitada =>
      settingValue<bool>(_map, 'caja_chica.habilitada', false);

  bool get auditVisibleAdminCobranza =>
      settingValue<bool>(_map, 'audit.visible_admin_cobranza', false);

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

  /// Título del documento en el recibo (ej: "COBRO", "RECIBO").
  String get reciboTitulo =>
      settingValue<String>(_map, 'recibo.titulo', 'RECIBO');

  /// Mostrar monto en letras en el recibo.
  bool get reciboMontoEnLetras =>
      settingValue<bool>(_map, 'recibo.monto_en_letras', true);

  /// Mostrar tabla de meses adeudados en el recibo.
  bool get reciboMostrarAdeudado =>
      settingValue<bool>(_map, 'recibo.mostrar_adeudado', true);

  /// Mostrar WhatsApp de la empresa en el recibo.
  String get empresaWhatsapp =>
      settingValue<String>(_map, 'empresa.whatsapp', '');

  /// Config del CHANGE LOG (Fase C): qué campos se muestran en el historial
  /// de cambios, por entidad. Lee el setting `audit.campos_visibles`, un map
  /// JSONB `{tabla: [campos]}`.
  ///
  /// Parseo defensivo: solo se incluyen las entidades presentes en el setting.
  /// Las entidades AUSENTES no se devuelven → el widget cae al default curado
  /// por tabla (`kAuditCamposVisiblesDefault`). Si el setting no existe o es
  /// inválido, devuelve `{}` (todo cae a default).
  Map<String, Set<String>> get auditCamposVisibles {
    final s = _map?['audit.campos_visibles'];
    if (s == null) return const {};
    final v = s.valor;
    // El Setting ya viene con `valor` decodificado (jsonDecode en fromRow).
    // Si por algún motivo llegó como string crudo, intentamos decodificar.
    dynamic raw = v;
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return const {};
      }
    }
    if (raw is! Map) return const {};
    final result = <String, Set<String>>{};
    raw.forEach((key, value) {
      if (key is! String) return;
      if (value is List) {
        result[key] = value.whereType<String>().toSet();
      }
    });
    return result;
  }
}

final appSettingsProvider = Provider<AppSettings>((ref) {
  final map = ref.watch(settingsMapProvider).valueOrNull;
  return AppSettings(map);
});
