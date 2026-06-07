import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_cambios_widget.dart';

/// CRUD de tipos de ticket (catálogo per-tenant con SLA por tipo). Solo admin.
class TicketTiposScreen extends ConsumerStatefulWidget {
  const TicketTiposScreen({super.key});
  @override
  ConsumerState<TicketTiposScreen> createState() => _TicketTiposScreenState();
}

class _TicketTiposScreenState extends ConsumerState<TicketTiposScreen> {
  late final Stream<List<Map<String, dynamic>>> _tipos;

  @override
  void initState() {
    super.initState();
    _tipos = ps.db.watch(
        'SELECT * FROM ticket_tipos WHERE activo = 1 ORDER BY orden, nombre');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Tipo'),
        onPressed: () => _crear(context),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _tipos,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          final rows = snap.data!;
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.label_outline,
              titulo: 'Sin tipos de ticket',
              descripcion: 'Definí los tipos (instalación, reparación…) con su SLA.',
              accion: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Agregar primero'),
                onPressed: () => _crear(context),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final t = rows[i];
              final sla = t['sla_horas'] as int?;
              return ListTile(
                leading: Icon(Icons.label_outline, color: scheme.outline),
                title: Text(t['nombre'] as String),
                subtitle: Text(sla != null ? 'SLA: $sla h' : 'Sin SLA'),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'editar') {
                      _crear(context, existente: t);
                    } else if (v == 'eliminar') {
                      _eliminar(context, t);
                    } else {
                      _showHistorial(context, t['id'] as String);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'editar', child: Text('Editar')),
                    PopupMenuItem(value: 'historial', child: Text('Historial')),
                    PopupMenuItem(value: 'eliminar', child: Text('Eliminar')),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _crear(BuildContext context,
      {Map<String, dynamic>? existente}) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final res = await showDialog<({String nombre, String? descripcion, int? sla})>(
      context: context,
      builder: (_) => _TipoDialog(existente: existente),
    );
    if (res == null) return;
    try {
      if (existente == null) {
        await ps.db.execute(
          'INSERT INTO ticket_tipos (id, tenant_id, nombre, descripcion, sla_horas, orden, activo, created_at) '
          'VALUES (?, ?, ?, ?, ?, 0, 1, ?)',
          [const Uuid().v4(), tenantId, res.nombre, res.descripcion, res.sla,
            DateTime.now().toIso8601String()],
        );
      } else {
        await ps.db.execute(
          'UPDATE ticket_tipos SET nombre = ?, descripcion = ?, sla_horas = ? WHERE id = ?',
          [res.nombre, res.descripcion, res.sla, existente['id']],
        );
      }
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }

  Future<void> _eliminar(BuildContext context, Map<String, dynamic> t) async {
    final id = t['id'] as String;
    // Guarda de "en uso": el FK tickets.tipo_id es ON DELETE RESTRICT.
    final usos = await ps.db.getAll(
        'SELECT COUNT(*) AS n FROM tickets WHERE tipo_id = ?', [id]);
    if (!context.mounted) return;
    final n = (usos.first['n'] as int?) ?? 0;
    if (n > 0) {
      _snack(context, 'No se puede eliminar: $n ticket(s) usan este tipo.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar'),
        content: Text('¿Eliminar el tipo "${t['nombre']}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ps.db.execute('DELETE FROM ticket_tipos WHERE id = ?', [id]);
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }

  void _showHistorial(BuildContext context, String id) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, sc) => SingleChildScrollView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('Historial del tipo',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              HistorialCambiosWidget(tabla: 'ticket_tipos', registroId: id),
            ],
          ),
        ),
      ),
    );
  }
}

class _TipoDialog extends StatefulWidget {
  const _TipoDialog({this.existente});
  final Map<String, dynamic>? existente;
  @override
  State<_TipoDialog> createState() => _TipoDialogState();
}

class _TipoDialogState extends State<_TipoDialog> {
  late final TextEditingController _nombre;
  late final TextEditingController _descripcion;
  late final TextEditingController _sla;

  @override
  void initState() {
    super.initState();
    final e = widget.existente;
    _nombre = TextEditingController(text: e?['nombre'] as String? ?? '');
    _descripcion =
        TextEditingController(text: e?['descripcion'] as String? ?? '');
    _sla = TextEditingController(
        text: (e?['sla_horas'] as int?)?.toString() ?? '');
  }

  @override
  void dispose() {
    _nombre.dispose();
    _descripcion.dispose();
    _sla.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existente == null ? 'Nuevo tipo' : 'Editar tipo'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nombre,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descripcion,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Descripción (opcional)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sla,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'SLA en horas (opcional)',
                hintText: 'Ej. 24',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final n = _nombre.text.trim();
            if (n.isEmpty) return;
            final slaTxt = _sla.text.trim();
            final sla = slaTxt.isEmpty ? null : int.tryParse(slaTxt);
            final desc = _descripcion.text.trim();
            Navigator.pop(context, (
              nombre: n,
              descripcion: desc.isEmpty ? null : desc,
              sla: sla,
            ));
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

void _snack(BuildContext context, String msg) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
