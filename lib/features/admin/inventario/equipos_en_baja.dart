import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/modulos_provider.dart';
import '../../../powersync/db.dart' as ps;

/// Cuando se CANCELA un contrato o se DESACTIVA un cliente que tiene equipos de
/// inventario INSTALADOS, ofrece (no bloqueante) devolverlos a stock o
/// retirarlos, para que no queden "fantasma" instalados en una entidad inactiva
/// (hallazgo ALTA del audit de lifecycle cross-módulo).
///
/// Filtra por `contratoId` (más específico) o por `clienteId`. No hace nada si
/// el módulo inventario está off o si no hay equipos instalados.
Future<void> ofrecerGestionEquiposEnBaja(
  BuildContext context,
  WidgetRef ref, {
  String? clienteId,
  String? contratoId,
  required String entidad, // 'contrato' | 'cliente' (para el texto)
}) async {
  final modulos = ref.read(modulosHabilitadosProvider).valueOrNull ?? {};
  if (!modulos.contains('inventario')) return;
  final tenantId = ref.read(tenantIdProvider);
  if (tenantId == null) return;
  final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;

  final filtro = contratoId != null ? 'contrato_id' : 'cliente_id';
  final param = contratoId ?? clienteId;
  if (param == null) return;

  final equipos = await ps.db.getAll(
    '''
    SELECT s.id, s.serial, s.producto_id, p.nombre AS producto
      FROM inv_seriales s
      JOIN inv_productos p ON p.id = s.producto_id
     WHERE s.$filtro = ? AND s.estado = 'instalado'
     ORDER BY p.nombre, s.serial
    ''',
    [param],
  );
  if (equipos.isEmpty || !context.mounted) return;

  final accion = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _GestionEquiposSheet(entidad: entidad, equipos: equipos),
  );
  if (accion == null || !context.mounted) return;

  if (accion == 'devolver') {
    final destino = await _pickUbicacionSimple(context);
    if (destino == null || !context.mounted) return;
    try {
      await _aplicarATodos(equipos, tenantId, hechoPor,
          tipo: 'devolucion', nuevoEstado: 'en_stock', ubicacion: destino.id);
      _snack(context, 'Equipos devueltos a ${destino.nombre}');
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  } else if (accion == 'retirar') {
    try {
      await _aplicarATodos(equipos, tenantId, hechoPor,
          tipo: 'baja', nuevoEstado: 'retirado', ubicacion: null);
      _snack(context, 'Equipos retirados');
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }
}

/// Aplica la transición a TODOS los equipos en una sola transacción atómica.
/// Re-valida que cada uno siga 'instalado' (idempotente si algo cambió).
Future<void> _aplicarATodos(
  List<Map<String, dynamic>> equipos,
  String tenantId,
  String? hechoPor, {
  required String tipo,
  required String nuevoEstado,
  String? ubicacion,
}) async {
  final now = DateTime.now().toIso8601String();
  await ps.db.writeTransaction((tx) async {
    for (final e in equipos) {
      final cur = await tx.getOptional(
          'SELECT estado, cliente_id, producto_id FROM inv_seriales WHERE id = ?',
          [e['id']]);
      if (cur == null || cur['estado'] != 'instalado') continue;
      if (tipo == 'devolucion') {
        await tx.execute(
          "UPDATE inv_seriales SET estado = 'en_stock', cliente_id = NULL, "
          "contrato_id = NULL, ubicacion_id = ? WHERE id = ?",
          [ubicacion, e['id']],
        );
        await tx.execute(
          '''INSERT INTO inv_movimientos
             (id, tenant_id, tipo, producto_id, serial_id, cantidad,
              ubicacion_destino_id, cliente_id, hecho_por, ocurrido_en, created_at)
             VALUES (?, ?, 'devolucion', ?, ?, 1, ?, ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, cur['producto_id'], e['id'],
            ubicacion, cur['cliente_id'], hechoPor, now, now,
          ],
        );
      } else {
        await tx.execute(
          'UPDATE inv_seriales SET estado = ?, cliente_id = NULL, ubicacion_id = NULL WHERE id = ?',
          [nuevoEstado, e['id']],
        );
        await tx.execute(
          '''INSERT INTO inv_movimientos
             (id, tenant_id, tipo, producto_id, serial_id, cantidad,
              cliente_id, motivo, hecho_por, ocurrido_en, created_at)
             VALUES (?, ?, 'baja', ?, ?, 1, ?, ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, cur['producto_id'], e['id'],
            cur['cliente_id'], 'Retiro por baja del $tipo', hechoPor, now, now,
          ],
        );
      }
    }
  });
}

class _GestionEquiposSheet extends StatelessWidget {
  const _GestionEquiposSheet({required this.entidad, required this.equipos});
  final String entidad;
  final List<Map<String, dynamic>> equipos;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Este $entidad tiene ${equipos.length} equipo'
                '${equipos.length != 1 ? 's' : ''} instalado'
                '${equipos.length != 1 ? 's' : ''}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ...equipos.take(6).map((e) => ListTile(
                  dense: true,
                  leading: Icon(Icons.qr_code_2, color: scheme.outline, size: 20),
                  title: Text(e['serial'] as String),
                  subtitle: Text(e['producto'] as String? ?? ''),
                )),
            if (equipos.length > 6)
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: Text('y ${equipos.length - 6} más…',
                    style: TextStyle(color: scheme.outline)),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.inventory),
              label: const Text('Devolver a stock'),
              onPressed: () => Navigator.pop(context, 'devolver'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.remove_circle_outline),
              label: const Text('Retirar (dar de baja)'),
              onPressed: () => Navigator.pop(context, 'retirar'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Dejar como están'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Selector simple de ubicación activa (para la devolución masiva).
Future<({String id, String nombre})?> _pickUbicacionSimple(
    BuildContext context) async {
  final ubis = await ps.db.getAll(
      'SELECT id, nombre FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre');
  if (!context.mounted) return null;
  if (ubis.isEmpty) {
    _snack(context, 'No hay ubicaciones. Creá una en Inventario primero.');
    return null;
  }
  return showDialog<({String id, String nombre})>(
    context: context,
    builder: (_) => SimpleDialog(
      title: const Text('Devolver a qué ubicación'),
      children: [
        for (final u in ubis)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(
                context, (id: u['id'] as String, nombre: u['nombre'] as String)),
            child: Text(u['nombre'] as String),
          ),
      ],
    ),
  );
}

void _snack(BuildContext context, String msg) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
