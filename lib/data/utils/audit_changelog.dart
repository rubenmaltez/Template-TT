import 'dart:convert';

import '../models/pago.dart';
import '../providers/audit_lookups_provider.dart';
import 'formatters.dart';

/// Un cambio individual de un campo dentro de un evento del audit log.
/// Se renderiza como "campo: antes → después".
class CampoChange {
  const CampoChange({
    required this.campo,
    required this.antes,
    required this.despues,
  });
  final String campo;
  final String antes;
  final String despues;
}

// ---------------------------------------------------------------------------
// Catálogo curado por entidad (allowlist). SOLO estos campos se muestran en
// el historial. Si la tabla NO está en el map, el comportamiento es permisivo
// (se muestran todos los campos que no estén en `kAuditSkipKeys`).
//
// La Fase C reemplazará estos defaults por un setting per-tenant; por eso
// `auditExtraerCambios` acepta un parámetro `camposVisibles` opcional.
// ---------------------------------------------------------------------------
const Map<String, Set<String>> kAuditCamposVisiblesDefault = {
  'pagos': {
    'fecha_pago',
    'monto_cordobas',
    'vuelto_cordobas',
    'metodo',
    'notas',
    'referencia',
    'anulado',
  },
  'cuotas': {
    'estado',
    'monto',
    'monto_pagado',
    'periodo',
    'fecha_vencimiento',
    'tipo_cargo_manual',
    'descripcion',
  },
  'clientes': {
    'codigo',
    'nombre',
    'telefono',
    'direccion',
    'cedula',
    'referencia',
    'notas',
    'activo',
    'cobrador_id',
    'comunidad_id',
  },
  'contratos': {
    'codigo',
    'estado',
    'precio_mensual',
    'dia_pago',
    'fecha_inicio',
    'fecha_fin',
    'duracion_meses',
    'plan_id',
    'cobrador_id',
  },
  'recibos': {
    'numero_completo',
    'anulado',
    'reimpresiones',
  },
  'cargos_extra': {
    'monto',
    'tipo',
    'descripcion',
  },
  'visitas': {
    'estado',
    'notas',
    'resultado',
  },
  'fotos_cliente': {
    'descripcion',
  },
  'planes': {
    'nombre',
    'tipo',
    'precio_mensual',
    'activo',
  },
};

// ---------------------------------------------------------------------------
// Campos de SUPERFICIE para hijas "contenedoras" dentro del log de su padre.
//
// Regla de profundidad del change log: el log de un padre agrega solo sus
// hijas DIRECTAS (un nivel), nunca nietas. Y para una hija que a su vez
// contiene otras entidades (ej. contrato → cuotas → pagos), el log del padre
// muestra solo sus eventos de SUPERFICIE (alta / baja / cambio de estado /
// reasignación de cobrador), NO sus ediciones puntuales de campos. Esas
// ediciones (precio, día de pago, plan, fechas) viven en el log propio de esa
// hija.
//
// Se usa pasando este set como `camposVisibles` a `auditExtraerCambios` para
// las filas de la hija contenedora: un update que solo tocó campos
// no-superficie queda con `cambios` vacío y se oculta; create/delete y los
// cambios de estado/cobrador siempre se ven.
// ---------------------------------------------------------------------------
const Map<String, Set<String>> kAuditCamposSuperficie = {
  // En el log del CLIENTE, del contrato solo interesa: existe / se canceló /
  // cambió de estado / se reasignó el cobrador.
  'contratos': {'estado', 'cobrador_id'},
};

// ---------------------------------------------------------------------------
// Catálogo de campos SELECCIONABLES por entidad (Fase C). Es el superset que
// el panel de configuración (`audit_campos_screen.dart`) ofrece como opciones
// al super_admin. El subconjunto efectivamente visible se guarda en el setting
// `audit.campos_visibles` per-tenant; si no hay setting, se usa el default
// curado de `kAuditCamposVisiblesDefault`.
//
// Orden de la lista = orden de presentación en el panel.
// ---------------------------------------------------------------------------
const Map<String, List<String>> kAuditCamposCatalogo = {
  'clientes': [
    'codigo',
    'nombre',
    'telefono',
    'direccion',
    'cedula',
    'referencia',
    'notas',
    'activo',
    'cobrador_id',
    'comunidad_id',
  ],
  'contratos': [
    'codigo',
    'estado',
    'precio_mensual',
    'dia_pago',
    'fecha_inicio',
    'fecha_fin',
    'duracion_meses',
    'documento_path',
    'plan_id',
    'cobrador_id',
  ],
  'cuotas': [
    'estado',
    'monto',
    'monto_pagado',
    'periodo',
    'fecha_vencimiento',
    'tipo_cargo_manual',
    'descripcion',
    'cargos_neto',
  ],
  'pagos': [
    'fecha_pago',
    'monto_cordobas',
    'vuelto_cordobas',
    'monto_original',
    'moneda',
    'tasa_conversion',
    'metodo',
    'referencia',
    'notas',
    'anulado',
  ],
  'recibos': [
    'numero_completo',
    'anulado',
    'reimpresiones',
  ],
  'cargos_extra': [
    'monto',
    'tipo',
    'descripcion',
  ],
  'visitas': [
    'estado',
    'notas',
    'resultado',
  ],
  'fotos_cliente': [
    'descripcion',
  ],
  'planes': [
    'nombre',
    'tipo',
    'precio_mensual',
    'activo',
  ],
};

// Label humano por entidad (para los títulos de las secciones del panel).
const Map<String, String> kAuditEntidadLabel = {
  'clientes': 'Clientes',
  'contratos': 'Contratos',
  'cuotas': 'Cuotas',
  'pagos': 'Pagos',
  'recibos': 'Recibos',
  'cargos_extra': 'Cargos manuales',
  'visitas': 'Visitas',
  'fotos_cliente': 'Fotos',
  'planes': 'Planes',
};

// Columnas computadas / auto que se omiten en cualquier snapshot, además del
// allowlist. Esto evita filtrar ids/FKs/geo aunque la tabla caiga al fallback
// permisivo (tabla no presente en el map de arriba).
const Set<String> kAuditSkipKeys = {
  'id', 'tenant_id', 'client_local_id', 'created_at', 'updated_at',
  'foto_comprobante_path',
  // Campos de anulación/auditoría que cargan la UI con nulls
  // cuando se muestra una creación o snapshot de delete.
  'anulado_en', 'anulado_por', 'motivo_anulacion',
  // FK ids siempre ocultos (no aportan info o ya están reflejados en otro
  // lado del card): id de la entidad misma, group, user resuelto via JOIN.
  'cuota_id', 'pago_id', 'recibo_id', 'grupo_cobro', 'user_id',
  // Geo del cobro: deprecado (ya no se captura ubicación al cobrar).
  'lat', 'lng',
};

// Campos de dinero que se muestran formateados como córdobas (C$X.XX).
const Set<String> kAuditMoneyKeys = {
  'monto', 'monto_pagado', 'monto_cordobas', 'vuelto_cordobas',
  'cargos_neto', 'monto_original', 'precio_mensual',
};

/// Detecta la acción real del evento. El trigger guarda 'update' para las
/// anulaciones, pero el JSONB nuevo contiene `anulado: 1`. Lo identificamos
/// para etiquetar el evento como 'anulacion'.
String auditDetectarAccion(Map<String, dynamic> row) {
  final accion = row['accion'] as String? ?? 'update';
  if (accion != 'update') return accion;
  try {
    final nuevoRaw = row['valor_nuevo'] as String?;
    if (nuevoRaw == null) return accion;
    final nuevo = jsonDecode(nuevoRaw);
    if (nuevo is Map) {
      // pagos/recibos usan columna `anulado`; cuotas usan estado='anulada'.
      if (nuevo['anulado'] == 1) return 'anulacion';
      if (nuevo['estado'] == 'anulada') return 'anulacion';
    }
  } catch (_) {}
  return accion;
}

/// Lee un campo del snapshot de una fila del audit_log (valor_nuevo con
/// fallback a valor_anterior). Útil para mostrar contexto que NO cambió en el
/// diff —ej. el número de recibo en una anulación, que sobrevive idéntico y por
/// eso no aparece como línea "antes → después". Devuelve null si no está o no
/// parsea.
String? auditSnapshotField(Map<String, dynamic> row, String key) {
  final raw = (row['valor_nuevo'] ?? row['valor_anterior']) as String?;
  if (raw == null) return null;
  try {
    final m = jsonDecode(raw);
    if (m is Map && m[key] != null) return m[key].toString();
  } catch (_) {}
  return null;
}

/// Devuelve `true` si el campo `key` debe mostrarse para la tabla `tabla`,
/// aplicando: skip global + allowlist (con fallback permisivo si la tabla no
/// está en el catálogo).
bool _campoVisible(String key, String? tabla, Set<String>? camposVisibles) {
  if (kAuditSkipKeys.contains(key)) return false;
  final allow = camposVisibles ?? kAuditCamposVisiblesDefault[tabla];
  // Fallback permisivo: tabla desconocida sin allowlist → mostrar todos los
  // campos no-skip.
  if (allow == null) return true;
  return allow.contains(key);
}

/// Reglas SMART que filtran un campo según su VALOR (no solo su nombre).
/// Devuelve `true` si el campo debe omitirse.
/// - `vuelto_cordobas`: solo si el valor relevante es > 0.
/// - `anulado`: solo cuando el valor nuevo es true/1 (no "Anulado: No").
bool _smartOmit(String key, dynamic valorRelevante) {
  if (key == 'vuelto_cordobas') {
    final n = _asNum(valorRelevante);
    if (n == null || n <= 0) return true;
  }
  if (key == 'anulado') {
    final esTrue = valorRelevante == true ||
        valorRelevante == 1 ||
        valorRelevante == '1' ||
        valorRelevante == 'true';
    if (!esTrue) return true;
  }
  return false;
}

num? _asNum(dynamic v) {
  if (v == null) return null;
  if (v is num) return v;
  return num.tryParse(v.toString());
}

/// Extrae la lista curada de cambios de una fila del audit_log.
///
/// - UPDATE (valor_anterior + valor_nuevo Maps): diff campo por campo.
/// - CREATE (solo valor_nuevo): "— → valor".
/// - DELETE (solo valor_anterior): "valor → —".
///
/// Aplica: skip global + allowlist (default por tabla si `camposVisibles` es
/// null) + reglas SMART por valor. En CREATE se omiten montos en cero y
/// nulls/vacíos.
List<CampoChange> auditExtraerCambios(
  Map<String, dynamic> row, {
  Set<String>? camposVisibles,
  AuditLookups? lookups,
}) {
  final tabla = row['tabla'] as String?;
  final anteriorRaw = row['valor_anterior'] as String?;
  final nuevoRaw = row['valor_nuevo'] as String?;
  if (anteriorRaw == null && nuevoRaw == null) return [];

  try {
    final anterior = anteriorRaw != null ? jsonDecode(anteriorRaw) : null;
    final nuevo = nuevoRaw != null ? jsonDecode(nuevoRaw) : null;

    // UPDATE: ambos snapshots → diff campo por campo.
    if (anterior is Map && nuevo is Map) {
      final cambios = <CampoChange>[];
      final allKeys = {...anterior.keys, ...nuevo.keys};
      for (final key in allKeys.cast<String>()) {
        if (!_campoVisible(key, tabla, camposVisibles)) continue;
        final a = anterior[key];
        final n = nuevo[key];
        if (a == n) continue;
        // Reglas SMART: en update el valor relevante es el nuevo.
        if (_smartOmit(key, n)) continue;
        cambios.add(CampoChange(
          campo: auditFieldLabel(key),
          antes: _fmtField(key, a, lookups: lookups),
          despues: _fmtField(key, n, lookups: lookups),
        ));
      }
      return cambios;
    }

    // CREATE: solo valor_nuevo. Valores iniciales no nulos como "— → valor".
    if (anterior == null && nuevo is Map) {
      return _snapshotAsCambios(
        nuevo,
        isCreate: true,
        tabla: tabla,
        camposVisibles: camposVisibles,
        lookups: lookups,
      );
    }

    // DELETE: solo valor_anterior. Valores eliminados como "valor → —".
    if (nuevo == null && anterior is Map) {
      return _snapshotAsCambios(
        anterior,
        isCreate: false,
        tabla: tabla,
        camposVisibles: camposVisibles,
        lookups: lookups,
      );
    }

    final campo = row['campo'] as String? ?? 'valor';
    if (!_campoVisible(campo, tabla, camposVisibles)) return [];
    return [
      CampoChange(
        campo: auditFieldLabel(campo),
        antes: _fmt(anterior),
        despues: _fmt(nuevo),
      ),
    ];
  } catch (_) {
    final campo = row['campo'] as String? ?? 'valor';
    if (!_campoVisible(campo, tabla, camposVisibles)) return [];
    return [
      CampoChange(
        campo: auditFieldLabel(campo),
        antes: anteriorRaw ?? '—',
        despues: nuevoRaw ?? '—',
      ),
    ];
  }
}

// Convierte un snapshot completo (create/delete) en una lista de cambios.
// - isCreate true:  "— → valor"  (campos del row inicial)
// - isCreate false: "valor → —"  (campos del row eliminado)
List<CampoChange> _snapshotAsCambios(
  Map snap, {
  required bool isCreate,
  required String? tabla,
  required Set<String>? camposVisibles,
  required AuditLookups? lookups,
}) {
  final cambios = <CampoChange>[];
  for (final entry in snap.entries) {
    final key = entry.key as String;
    if (!_campoVisible(key, tabla, camposVisibles)) continue;
    final v = entry.value;
    // Omitir nulls y vacíos del snapshot (no aportan info).
    if (v == null) continue;
    if (v is String && v.isEmpty) continue;
    // En creaciones, omitir montos/contadores en cero (ruido tipo
    // "— → C$0.00" o "Reimpresiones: — → 0"; toda entidad arranca con esos en
    // 0). reimpresiones aparece en el snapshot de un recibo recién emitido.
    if (isCreate && (kAuditMoneyKeys.contains(key) || key == 'reimpresiones')) {
      final n = _asNum(v);
      if (n != null && n == 0) continue;
    }
    // Reglas SMART: el valor relevante del snapshot es el propio `v`.
    if (_smartOmit(key, v)) continue;
    final formateado = _fmtField(key, v, lookups: lookups);
    cambios.add(CampoChange(
      campo: auditFieldLabel(key),
      antes: isCreate ? '—' : formateado,
      despues: isCreate ? formateado : '—',
    ));
  }
  return cambios;
}

// Formatea un valor teniendo en cuenta el nombre del campo: los campos de
// dinero se renderizan con `Fmt.cordobas` (C$500.00); enums con su label
// humano; FKs con `lookups` (UUID → nombre); el resto cae al formateo
// genérico de `_fmt`.
String _fmtField(String key, dynamic v, {AuditLookups? lookups}) {
  if (kAuditMoneyKeys.contains(key)) {
    if (v == null) return '—';
    if (v is num) return Fmt.cordobas(v);
    final n = num.tryParse(v.toString());
    if (n != null) return Fmt.cordobas(n);
  }
  // Enums: mostrar el label humano que usa el resto de la app, no el slug.
  if (key == 'metodo' && v is String && v.isNotEmpty) {
    return MetodoPago.fromString(v).label;
  }
  if (key == 'tipo_cargo_manual' && v is String && v.isNotEmpty) {
    return _tipoCargoLabel(v);
  }
  // cargos_extra.tipo: enum con su propio set de valores.
  if (key == 'tipo' && v is String && v.isNotEmpty) {
    return _tipoCargoExtraLabel(v);
  }
  // FKs: resolver UUID a nombre humano. Si el lookup no encontró match
  // (entidad eliminada o aún no sincronizada), mostramos "(eliminado)" en
  // lugar de exponer el UUID crudo.
  if (lookups != null && v is String && v.isNotEmpty) {
    final resolved = lookups.resolve(key, v);
    if (resolved != null) return resolved;
    // ¿Era una clave FK conocida? Si sí, no se encontró el nombre.
    if (_kClavesFk.contains(key)) return '(eliminado)';
  }
  return _fmt(v);
}

// Claves de columnas que sabemos resolver via AuditLookups. Si una de estas
// llega sin match en los lookups, mostramos "(eliminado)" en vez del UUID.
const Set<String> _kClavesFk = {
  'cobrador_id', 'cliente_id', 'plan_id', 'contrato_id',
  'comunidad_id', 'departamento_id', 'municipio_id',
  'anulado_por', 'user_id',
};

String _tipoCargoExtraLabel(String t) => switch (t) {
      'descuento_monto' => 'Descuento (monto fijo)',
      'descuento_porcentaje' => 'Descuento (porcentaje)',
      'reconexion' => 'Reconexión',
      'otro' => 'Otro',
      _ => t,
    };

String _tipoCargoLabel(String t) => switch (t) {
      'reconexion' => 'Reconexión',
      'instalacion' => 'Instalación',
      'mora' => 'Mora',
      'reparacion' => 'Reparación',
      'otro' => 'Otro',
      _ => t,
    };

String _fmt(dynamic v) {
  if (v == null) return '—';
  if (v is bool) return v ? 'Sí' : 'No';
  if (v is num) return v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 2);
  final s = v.toString();
  if (s.length >= 19 && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) {
    final dt = DateTime.tryParse(s);
    if (dt != null) return Fmt.fechaCorta(dt);
  }
  // Tope GENEROSO solo como guarda contra blobs absurdos: el tile del historial
  // ya hace wrap del texto, así que valores normales (ej. las NOTAS que deja el
  // cobrador al cobrar) se muestran COMPLETOS. Antes el tope de 30 chars cortaba
  // las notas con "…".
  if (s.length > 500) return '${s.substring(0, 497)}…';
  return s;
}

/// Label humano para una columna del audit_log.
String auditFieldLabel(String raw) {
  const labels = {
    'monto_cordobas': 'Monto',
    'monto_original': 'Monto original',
    'monto_pagado': 'Monto pagado',
    'vuelto_cordobas': 'Vuelto',
    'fecha_pago': 'Fecha de pago',
    'fecha_vencimiento': 'Fecha vencimiento',
    'fecha_inicio': 'Fecha inicio',
    'fecha_fin': 'Fecha fin',
    'cobrador_id': 'Cobrador',
    'cliente_id': 'Cliente',
    'contrato_id': 'Contrato',
    'cuota_id': 'Cuota',
    'plan_id': 'Plan',
    'metodo': 'Método de pago',
    'moneda': 'Moneda',
    'tasa_conversion': 'Tasa de conversión',
    'anulado': 'Anulado',
    'anulado_en': 'Anulado en',
    'anulado_por': 'Anulado por',
    'motivo_anulacion': 'Motivo anulación',
    'estado': 'Estado',
    'monto': 'Monto',
    'periodo': 'Período',
    'codigo': 'Código',
    'nombre': 'Nombre',
    'telefono': 'Teléfono',
    'direccion': 'Dirección',
    'cedula': 'Cédula',
    'comunidad_id': 'Comunidad',
    'departamento_id': 'Departamento',
    'municipio_id': 'Municipio',
    'activo': 'Activo',
    'referencia': 'Referencia',
    'notas': 'Notas',
    'descripcion': 'Descripción',
    'numero_completo': 'Número recibo',
    'grupo_cobro': 'Cobro agrupado',
    'cargos_neto': 'Cargos neto',
    'lat': 'Latitud',
    'lng': 'Longitud',
    'dia_pago': 'Día de pago',
    'reimpresiones': 'Reimpresiones',
    'documento_path': 'Documento adjunto',
    'precio_mensual': 'Precio mensual',
    'tipo_cargo_manual': 'Tipo de cargo',
    'pago_id': 'Pago',
    'recibo_id': 'Recibo',
    'numero': 'Número',
    'prefijo': 'Prefijo',
    'serie': 'Serie',
    'rol': 'Rol',
    'email': 'Email',
    'prefijo_recibo': 'Prefijo recibo',
    'duracion_meses': 'Duración (meses)',
    'tipo': 'Tipo',
    'resultado': 'Resultado',
  };
  return labels[raw] ??
      raw
          .replaceAll('_', ' ')
          .replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase());
}
