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

  Table('clientes', [
    Column.text('tenant_id'),
    Column.text('cobrador_id'),
    Column.text('nombre'),
    Column.text('cedula'),
    Column.text('telefono'),
    Column.text('direccion'),
    Column.text('zona'),
    Column.real('latitud'),
    Column.real('longitud'),
    Column.text('foto_path'),
    Column.integer('activo'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ], indexes: [
    Index('by_cobrador', [
      IndexedColumn('tenant_id'),
      IndexedColumn('cobrador_id'),
    ]),
  ]),

  Table('contratos', [
    Column.text('tenant_id'),
    Column.text('cliente_id'),
    Column.text('cobrador_id'),
    Column.text('plan_id'),
    Column.integer('dia_corte'),
    Column.text('fecha_inicio'),
    Column.text('fecha_fin'),
    Column.integer('activo'),
    Column.text('created_at'),
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
    Column.text('estado'),
    Column.text('created_at'),
  ], indexes: [
    Index('by_cliente_estado', [
      IndexedColumn('cliente_id'),
      IndexedColumn('estado'),
    ]),
    Index('by_vencimiento', [IndexedColumn('fecha_vencimiento')]),
  ]),

  Table('pagos', [
    Column.text('tenant_id'),
    Column.text('cuota_id'),
    Column.text('cobrador_id'),
    Column.real('monto'),
    Column.text('metodo'),
    Column.text('recibo_numero'),
    Column.text('notas'),
    Column.text('fecha_pago'),
    Column.text('client_local_id'),
  ], indexes: [
    Index('by_cuota', [IndexedColumn('cuota_id')]),
    Index('by_fecha', [IndexedColumn('fecha_pago')]),
  ]),

  // Vista limitada — solo la baja el bucket `todo_tenant_admin`.
  Table('cobradores', [
    Column.text('tenant_id'),
    Column.text('nombre'),
    Column.text('rol'),
    Column.integer('activo'),
  ]),
]);
