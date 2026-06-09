import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../models/recibo_layout.dart';
import '../models/setting.dart';
import '../providers/cobrador_provider.dart';
import '../providers/db_epoch_provider.dart';
import '../utils/cuota_estado_visual.dart';

class SettingsRepo {
  const SettingsRepo();

  /// [tenantId]: filtra los settings al tenant efectivo. CRÍTICO durante
  /// impersonación — el SQLite del super_admin tiene settings de DOS tenants
  /// (System + impersonado) con las MISMAS claves; sin el filtro `map[clave]`
  /// se quedaba con una fila no determinista (M4 del audit). Para un admin
  /// normal el SQLite es mono-tenant, así que el filtro es inocuo. Null → sin filtro.
  Stream<Map<String, Setting>> watchAll({String? tenantId}) {
    final where = tenantId != null ? 'WHERE tenant_id = ?' : '';
    final params = tenantId != null ? <Object?>[tenantId] : <Object?>[];
    return ps.db
        .watch('SELECT * FROM settings $where ORDER BY categoria, clave',
            parameters: params)
        .map((rows) {
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
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  // Filtra al tenant efectivo (propio o impersonado) para no mezclar settings
  // de dos tenants en el SQLite del super_admin durante impersonación (M4).
  final tenantId = ref.watch(tenantIdProvider);
  return ref.watch(settingsRepoProvider).watchAll(tenantId: tenantId);
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

  // Efectivo es el método de pago POR DEFECTO e INMUTABLE: siempre disponible.
  // No se puede desactivar (sino el cobrador podría quedar sin ningún método y
  // se rompería el cobro). El toggle en settings se muestra fijo en ON.
  bool get efectivoHabilitado => true;

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

  /// Switch maestro de la foto de comprobante. Default FALSE → el cobro NO sube
  /// fotos (cero consumo de Storage). Solo el super_admin lo habilita por tenant
  /// (el toggle vive gateado en settings). `fotoObligatoria` solo aplica si esto
  /// está en ON.
  bool get comprobanteHabilitado =>
      settingValue<bool>(_map, 'cobranza.comprobante_habilitado', false);

  /// Pantalla admin opcional `/admin/pagos` (historial de pagos + anular),
  /// habilitada por el super_admin por tenant (toggle super_admin-only en
  /// settings). Default FALSE → el item del menú no aparece.
  bool get pantallaPagosHabilitada =>
      settingValue<bool>(_map, 'cobranza.pantalla_pagos', false);

  /// Visibilidad del panel de Auditoría (/admin/audit) para el admin del
  /// tenant. Default FALSE → el item del menú no aparece y el router rebota la
  /// ruta. Lo habilita el super_admin por tenant (toggle super_admin-only,
  /// migración 0089). El super_admin lo ve siempre, sin importar este valor.
  bool get auditVisibleAdmin =>
      settingValue<bool>(_map, 'cobranza.audit_visible_admin', false);

  bool get pagoParcialPermitido =>
      settingValue<bool>(_map, 'cobranza.pago_parcial', true);
  bool get pagoAdelantadoPermitido =>
      settingValue<bool>(_map, 'cobranza.pago_adelantado', true);

  int get diasCuotasVisibles =>
      settingValue<num>(_map, 'cobranza.dias_cuotas_visibles', 5).toInt();

  /// Colores configurables por estado de cuota (setting `cobranza.colores_estados`,
  /// map JSONB `{mora,gracia,hoy,proxima}` → "#RRGGBB"). Si falta o es inválido,
  /// cae a [ColoresEstados.defaults]. Fuente única de color para mapa, lista de
  /// cobros, cuotas admin, detalle de contrato y lista de clientes.
  ColoresEstados get coloresEstados {
    final s = _map?['cobranza.colores_estados'];
    if (s == null) return ColoresEstados.defaults;
    dynamic raw = s.valor;
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return ColoresEstados.defaults;
      }
    }
    if (raw is! Map) return ColoresEstados.defaults;
    return ColoresEstados.fromJson(raw);
  }

  /// Valor del descuento pronto pago. 0 = deshabilitado.
  double get descuentoProntoPago =>
      settingValue<num>(_map, 'cuotas.descuento_pronto_pago', 0).toDouble();

  /// Tipo de descuento: 'porcentaje' o 'monto'.
  String get descuentoProntoPagoTipo =>
      settingValue<String>(_map, 'cuotas.descuento_pronto_pago_tipo', 'porcentaje');

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

  /// Título del documento en el recibo (ej: "COBRO", "RECIBO").
  String get reciboTitulo =>
      settingValue<String>(_map, 'recibo.titulo', 'RECIBO');

  /// Mostrar tabla de meses adeudados en el recibo.
  bool get reciboMostrarAdeudado =>
      settingValue<bool>(_map, 'recibo.mostrar_adeudado', true);

  /// Mostrar WhatsApp de la empresa en el recibo.
  String get empresaWhatsapp =>
      settingValue<String>(_map, 'empresa.whatsapp', '');

  /// Mostrar la cédula del cliente en el recibo (#8b).
  bool get reciboMostrarCedula =>
      settingValue<bool>(_map, 'recibo.mostrar_cedula', true);

  /// Layout configurable del recibo (rework "diseñador de recibo"): lista
  /// ORDENADA de bloques, cada uno con visibilidad + tamaño de letra. Default =
  /// orden del catálogo, todo visible, normal. Parseo robusto: ver
  /// `ReciboLayout.fromRaw` (sanea ids desconocidos, completa faltantes, fuerza
  /// visible en los totales).
  List<ReciboBloque> get reciboLayout =>
      ReciboLayout.fromRaw(_map?['recibo.layout']?.valor);

  /// Tickets (Fase 3) — SLA de respuesta por PRIORIDAD, en horas (setting
  /// `tickets.sla_horas_por_prioridad`, map JSONB `{urgente, alta, media, baja}`).
  /// El SLA EFECTIVO de un ticket es el MENOR entre esto y el SLA del tipo (ver
  /// `slaHorasEfectivas`). Sólo se devuelven niveles con valor > 0 — un nivel en
  /// 0/ausente significa "sin SLA por prioridad" → cae al del tipo. Si el setting
  /// NO existe, default razonable out-of-the-box (urgente 1h … baja 12h).
  Map<String, int> get slaHorasPorPrioridad {
    const def = {'urgente': 1, 'alta': 2, 'media': 6, 'baja': 12};
    final s = _map?['tickets.sla_horas_por_prioridad'];
    if (s == null) return def;
    dynamic raw = s.valor;
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return def;
      }
    }
    if (raw is! Map) return def;
    final result = <String, int>{};
    raw.forEach((k, v) {
      if (k is String && v is num && v > 0) result[k] = v.toInt();
    });
    return result;
  }

  /// Tickets — días para auto-cerrar un ticket 'resuelto' sin reapertura (setting
  /// `tickets.auto_cierre_dias`). 0 = desactivado (default). El cron diario (0109)
  /// lo lee server-side; este getter alimenta el editor en la pantalla de Tipos.
  int get autoCierreDias =>
      settingValue<num>(_map, 'tickets.auto_cierre_dias', 0).toInt();

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
