// Schema del SQLite local que PowerSync mantiene sincronizado con Postgres.
//
// Reglas de tipo:
//   uuid / text / date / timestamptz → Column.text
//   numeric(10,2) / double precision → Column.real
//   boolean / int                    → Column.integer (SQLite no tiene bool)
//
// La columna `id` (text) se incluye automáticamente — no se declara.

import 'package:powersync/powersync.dart';

const schema = Schema([
  // ── Catálogos geo (per-tenant desde migración 0097) ───────────────────────
  Table('departamentos', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('codigo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  Table('municipios', [
    Column.text('tenant_id'),
    Column.text('departamento_id'),
    Column.text('nombre'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_departamento', [
      IndexedColumn('tenant_id'),
      IndexedColumn('departamento_id'),
    ]),
  ]),

  Table('comunidades', [
    Column.text('tenant_id'),
    Column.text('municipio_id'),
    Column.text('nombre'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_municipio', [
      IndexedColumn('tenant_id'),
      IndexedColumn('municipio_id'),
    ]),
  ]),

  // ── Topología de red (per-tenant, migración 0098): Nodo → Hub → Puerto ────
  Table('red_nodos', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('codigo'),
    Column.text('notas'),
    Column.integer('activo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  Table('red_hubs', [
    Column.text('tenant_id'),
    Column.text('nodo_id'),
    Column.text('nombre'),
    Column.text('codigo'),
    Column.integer('activo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_nodo', [IndexedColumn('tenant_id'), IndexedColumn('nodo_id')]),
  ]),

  Table('red_puertos', [
    Column.text('tenant_id'),
    Column.text('hub_id'),
    Column.text('nombre'),
    Column.text('codigo'),
    Column.integer('activo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_hub', [IndexedColumn('tenant_id'), IndexedColumn('hub_id')]),
  ]),

  // ── Catálogo del tenant ───────────────────────────────────────────────────
  Table('planes', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('tipo'),
    Column.real('precio_mensual'),
    Column.integer('activo'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_tenant', [IndexedColumn('tenant_id')]),
  ]),

  Table('settings', [
    Column.text('tenant_id'),
    Column.text('clave'),
    Column.text('valor'),
    Column.text('tipo'),
    Column.text('categoria'),
    Column.text('descripcion'),
    Column.text('editable_por'),
    Column.text('updated_at'),
  ], indexes: [
    Index('by_categoria', [
      IndexedColumn('tenant_id'),
      IndexedColumn('categoria'),
    ]),
  ]),

  // ── Operativas ────────────────────────────────────────────────────────────
  Table('clientes', [
    Column.text('tenant_id'),
    Column.text('cobrador_id'),
    Column.text('comunidad_id'),
    Column.text('puerto_id'),
    Column.text('codigo'),
    Column.text('nombre'),
    Column.text('cedula'),
    Column.text('telefono'),
    Column.text('direccion'),
    Column.text('direccion_referencia'),
    Column.real('latitud'),
    Column.real('longitud'),
    Column.text('foto_path'),
    Column.integer('activo'),
    Column.text('created_at'),
    Column.text('updated_at'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cobrador', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cobrador_id'),
    ]),
    Index('by_comunidad', [IndexedColumn('comunidad_id')]),
  ]),

  Table('contratos', [
    Column.text('tenant_id'),
    Column.text('cliente_id'),
    Column.text('codigo'),
    Column.text('cobrador_id'),
    Column.text('plan_id'),
    Column.integer('dia_pago'),
    Column.text('fecha_inicio'),
    Column.text('fecha_fin'),
    Column.integer('duracion_meses'),
    Column.text('fecha_primer_cobro'),
    Column.real('costo_instalacion'),
    Column.text('notas'),
    Column.text('estado'),
    Column.text('documento_path'),
    Column.text('created_at'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cliente', [IndexedColumn('cliente_id')]),
  ]),

  Table('cuotas', [
    Column.text('tenant_id'),
    Column.text('contrato_id'),
    Column.text('cliente_id'),
    Column.text('cobrador_id'),
    Column.text('periodo'),
    Column.text('fecha_vencimiento'),
    Column.real('monto'),
    Column.real('monto_pagado'),
    Column.real('cargos_neto'),
    Column.text('estado'),
    Column.text('anulada_en'),
    Column.text('anulada_por'),
    Column.text('motivo_anulacion'),
    Column.text('descripcion'),
    Column.text('tipo_cargo_manual'),
    Column.text('created_at'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cobrador_estado', [
      IndexedColumn('cobrador_id'),
      IndexedColumn('estado'),
    ]),
    Index('by_cliente', [IndexedColumn('cliente_id')]),
    Index('by_vencimiento', [IndexedColumn('fecha_vencimiento')]),
  ]),

  Table('pagos', [
    Column.text('tenant_id'),
    Column.text('cuota_id'),
    Column.text('cobrador_id'),
    Column.real('monto_cordobas'),
    Column.real('vuelto_cordobas'),
    Column.text('moneda'),
    Column.real('monto_original'),
    Column.real('tasa_conversion'),
    Column.text('metodo'),
    Column.text('referencia'),
    Column.text('foto_comprobante_path'),
    Column.real('lat'),
    Column.real('lng'),
    Column.text('notas'),
    Column.text('fecha_pago'),
    Column.integer('anulado'),
    Column.text('anulado_en'),
    Column.text('anulado_por'),
    Column.text('motivo_anulacion'),
    Column.text('grupo_cobro'),
    Column.text('client_local_id'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cuota', [IndexedColumn('cuota_id')]),
    Index('by_fecha', [IndexedColumn('fecha_pago')]),
    Index('by_cobrador_fecha', [
      IndexedColumn('cobrador_id'),
      IndexedColumn('fecha_pago'),
    ]),
    Index('by_grupo_cobro', [IndexedColumn('grupo_cobro')]),
  ]),

  Table('recibos', [
    Column.text('tenant_id'),
    Column.text('pago_id'),
    Column.text('cobrador_id'),
    Column.text('prefijo'),
    Column.integer('correlativo'),
    Column.text('numero_completo'),
    Column.text('impreso_en'),
    Column.integer('reimpresiones'),
    Column.integer('ultimo_formato_mm'),
    Column.integer('anulado'),
    Column.text('anulado_en'),
    Column.text('anulado_por'),
    Column.text('created_at'),
    Column.text('client_local_id'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_correlativo', [
      IndexedColumn('cobrador_id'),
      IndexedColumn('prefijo'),
      IndexedColumn('correlativo'),
    ]),
  ]),

  Table('cargos_extra', [
    Column.text('tenant_id'),
    Column.text('cuota_id'),
    Column.text('cobrador_id'),
    Column.text('tipo'),
    Column.real('monto'),
    Column.real('porcentaje'),
    Column.text('descripcion'),
    Column.text('aplicado_por'),
    Column.text('aplicado_en'),
    Column.text('client_local_id'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cuota', [IndexedColumn('cuota_id')]),
  ]),

  Table('notificaciones_mora', [
    Column.text('tenant_id'),
    Column.text('cuota_id'),
    Column.text('cliente_id'),
    Column.text('cobrador_id'),
    Column.integer('dias_mora'),
    Column.real('monto_adeudado'),
    Column.text('generada_en'),
    Column.text('vista_en'),
    Column.text('vista_por'),
    Column.text('resuelta_en'),
    Column.text('resuelta_por'),
  ], indexes: [
    Index('by_cobrador_resuelta', [
      IndexedColumn('cobrador_id'),
      IndexedColumn('resuelta_en'),
    ]),
  ]),

  // Audit log — sólo se baja a admin/admin_cobranza via sync rules.
  Table('audit_log', [
    Column.text('tenant_id'),
    Column.text('tabla'),
    Column.text('registro_id'),
    Column.text('campo'),
    Column.text('valor_anterior'),
    Column.text('valor_nuevo'),
    Column.text('accion'),
    Column.text('user_id'),
    Column.text('user_rol'),
    Column.text('created_at'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_tabla', [
      IndexedColumn('tenant_id'),
      IndexedColumn('tabla'),
    ]),
    Index('by_registro', [
      IndexedColumn('registro_id'),
      IndexedColumn('created_at'),
    ]),
    Index('by_fecha', [IndexedColumn('created_at')]),
  ]),

  // Vista limitada del cobrador (su propia fila) o del tenant entero
  // (bucket admin/admin_cobranza).
  Table('cobradores', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('telefono'),
    Column.text('rol'),
    Column.text('prefijo_recibo'),
    Column.integer('activo'),
  ]),

  // ── Fotos del cliente (max 10 por cliente) ──────────────────────────
  Table('fotos_cliente', [
    Column.text('tenant_id'),
    Column.text('cliente_id'),
    Column.text('cobrador_id'),
    Column.text('storage_path'),
    Column.text('created_at'),
    Column.text('created_by'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cliente', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cliente_id'),
    ]),
    Index('by_cobrador', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cobrador_id'),
    ]),
  ]),

  // ── Visitas registradas por el cobrador ─────────────────────────────
  Table('visitas', [
    Column.text('tenant_id'),
    Column.text('cliente_id'),
    Column.text('cobrador_id'),
    Column.text('resultado'),
    Column.text('notas'),
    Column.text('fecha'),
    Column.text('ocurrido_en'),
  ], indexes: [
    Index('by_cliente', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cliente_id'),
    ]),
    Index('by_cobrador', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cobrador_id'),
    ]),
  ]),

  // ── Impersonación de tenant por super_admin ──────────────────────────
  // Una sola row (o ninguna) por super_admin. Sincronizada vía el bucket
  // `impersonated_tenant` en sync-rules.yaml. Cuando existe, indica que
  // el super_admin está "dentro" de un tenant y la app muestra el
  // AdminShell con la data de ese tenant.
  Table('super_admin_impersonation', [
    Column.text('user_id'),
    Column.text('tenant_id'),
    Column.text('started_at'),
  ]),
]);
