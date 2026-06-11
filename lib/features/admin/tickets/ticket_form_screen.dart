import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/utils/ticket_sla.dart';
import '../../../powersync/db.dart' as ps;
import '../../../data/utils/errores.dart';

/// Crear un ticket. El correlativo se computa cliente-side (MAX+1 por tenant);
/// el UNIQUE(tenant,correlativo) del server es la red dura. Al crear se registra
/// el evento `creado` (+ `asignado` si se asigna un técnico) en la bitácora.
class TicketFormScreen extends ConsumerStatefulWidget {
  const TicketFormScreen({super.key});
  @override
  ConsumerState<TicketFormScreen> createState() => _TicketFormScreenState();
}

class _TicketFormScreenState extends ConsumerState<TicketFormScreen> {
  String? _tipoId;
  String? _clienteId;
  String? _clienteNombre;
  String? _asignadoA;
  String? _incidenteId;
  String _prioridad = 'media';
  final _titulo = TextEditingController();
  final _descripcion = TextEditingController();
  bool _guardando = false;

  late final Stream<List<Map<String, dynamic>>> _tipos;
  late final Stream<List<Map<String, dynamic>>> _tecnicos;
  late final Stream<List<Map<String, dynamic>>> _incidentes;

  @override
  void initState() {
    super.initState();
    _tipos = ps.db.watch(
        'SELECT id, nombre, sla_horas FROM ticket_tipos WHERE activo = 1 ORDER BY orden, nombre');
    _tecnicos = ps.db.watch(
        "SELECT id, nombre FROM cobradores WHERE activo = 1 AND rol IN ('tecnico','admin_tickets','admin') ORDER BY nombre");
    _incidentes = ps.db.watch(
        "SELECT id, titulo FROM incidentes WHERE estado = 'abierto' ORDER BY inicio DESC");
  }

  @override
  void dispose() {
    _titulo.dispose();
    _descripcion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          // Tipo (define el SLA).
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _tipos,
            initialData: const [],
            builder: (context, snap) {
              final rows = snap.data!;
              final exists =
                  _tipoId == null || rows.any((r) => r['id'] == _tipoId);
              return DropdownButtonFormField<String?>(
                initialValue: exists ? _tipoId : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Tipo de ticket'),
                onChanged: (v) => setState(() => _tipoId = v),
                items: rows
                    .map((r) => DropdownMenuItem(
                          value: r['id'] as String,
                          child: Text(r['nombre'] as String),
                        ))
                    .toList(),
              );
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _titulo,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Título'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descripcion,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration:
                const InputDecoration(labelText: 'Descripción (opcional)'),
          ),
          const SizedBox(height: 12),
          // Cliente (opcional: outage/instalación pre-contrato no lo tienen).
          InkWell(
            onTap: _elegirCliente,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Cliente (opcional)',
                suffixIcon: _clienteId != null
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() {
                          _clienteId = null;
                          _clienteNombre = null;
                        }),
                      )
                    : const Icon(Icons.search),
              ),
              child: Text(_clienteNombre ?? 'Sin cliente',
                  style: _clienteNombre == null
                      ? TextStyle(color: Theme.of(context).colorScheme.outline)
                      : null),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _prioridad,
            decoration: const InputDecoration(labelText: 'Prioridad'),
            onChanged: (v) => setState(() => _prioridad = v ?? 'media'),
            items: kTicketPrioridades
                .map((p) =>
                    DropdownMenuItem(value: p, child: Text(prioridadLabel(p))))
                .toList(),
          ),
          const SizedBox(height: 12),
          // Asignar a (opcional).
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _tecnicos,
            initialData: const [],
            builder: (context, snap) {
              final rows = snap.data!;
              final exists =
                  _asignadoA == null || rows.any((r) => r['id'] == _asignadoA);
              return DropdownButtonFormField<String?>(
                initialValue: exists ? _asignadoA : null,
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'Asignar a (opcional)'),
                onChanged: (v) => setState(() => _asignadoA = v),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('— Sin asignar —')),
                  ...rows.map((r) => DropdownMenuItem(
                        value: r['id'] as String,
                        child: Text(r['nombre'] as String),
                      )),
                ],
              );
            },
          ),
          // Incidente (opcional): sólo si hay outages abiertos para agrupar.
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _incidentes,
            initialData: const [],
            builder: (context, snap) {
              final rows = snap.data ?? const [];
              if (rows.isEmpty) return const SizedBox.shrink();
              final exists = _incidenteId == null ||
                  rows.any((r) => r['id'] == _incidenteId);
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: DropdownButtonFormField<String?>(
                  initialValue: exists ? _incidenteId : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Incidente / corte (opcional)'),
                  onChanged: (v) => setState(() => _incidenteId = v),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('— Ninguno —')),
                    ...rows.map((r) => DropdownMenuItem(
                          value: r['id'] as String,
                          child: Text(r['titulo'] as String,
                              overflow: TextOverflow.ellipsis),
                        )),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.save),
            label: const Text('Crear ticket'),
            onPressed: _guardando ? null : _guardar,
          ),
        ],
      ),
    );
  }

  Future<void> _elegirCliente() async {
    final res = await showModalBottomSheet<({String id, String nombre})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ClienteSearchSheet(),
    );
    if (res != null) {
      setState(() {
        _clienteId = res.id;
        _clienteNombre = res.nombre;
      });
    }
  }

  Future<void> _guardar() async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    if (_tipoId == null) {
      _snack('Elegí un tipo de ticket.');
      return;
    }
    if (_titulo.text.trim().isEmpty) {
      _snack('Poné un título.');
      return;
    }
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    setState(() => _guardando = true);

    // puerto_id derivado del cliente (si tiene), para enganchar la red.
    String? puertoId;
    if (_clienteId != null) {
      final c = await ps.db.getOptional(
          'SELECT puerto_id FROM clientes WHERE id = ?', [_clienteId]);
      puertoId = c?['puerto_id'] as String?;
    }

    // Snapshot del checklist del tipo (template → [{texto, hecho:false}]). El
    // snapshot vive en el ticket: editar el template después NO toca este ticket.
    var checklistJson = '[]';
    final tipoRow = await ps.db.getOptional(
        'SELECT checklist_template FROM ticket_tipos WHERE id = ?', [_tipoId]);
    final tmplRaw = tipoRow?['checklist_template'];
    if (tmplRaw is String && tmplRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(tmplRaw);
        if (decoded is List) {
          checklistJson = jsonEncode([
            for (final p in decoded.whereType<String>())
              {'texto': p, 'hecho': false}
          ]);
        }
      } catch (_) {}
    }

    final maxRow = await ps.db.getAll(
        'SELECT COALESCE(MAX(correlativo), 0) + 1 AS n FROM tickets WHERE tenant_id = ?',
        [tenantId]);
    final correlativo = (maxRow.first['n'] as int?) ?? 1;
    final id = const Uuid().v4();
    final estado = _asignadoA != null ? 'asignado' : 'abierto';
    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc().toIso8601String();

    try {
      await ps.db.writeTransaction((tx) async {
        await tx.execute(
          '''INSERT INTO tickets
             (id, tenant_id, correlativo, tipo_id, cliente_id, puerto_id,
              incidente_id, titulo, descripcion, estado, prioridad, asignado_a,
              creado_por, created_at, ocurrido_en, checklist)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            id, tenantId, correlativo, _tipoId, _clienteId, puertoId,
            _incidenteId, _titulo.text.trim(),
            _descripcion.text.trim().isEmpty ? null : _descripcion.text.trim(),
            estado, _prioridad, _asignadoA, hechoPor, now, ocurrido, checklistJson,
          ],
        );
        await _evento(tx, id, tenantId, 'creado', null, estado, hechoPor,
            ocurrido, now);
        if (_asignadoA != null) {
          await _evento(tx, id, tenantId, 'asignado', 'abierto', 'asignado',
              hechoPor, ocurrido, now);
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ticket ${ticketCodigo(correlativo)} creado')));
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/admin/tickets');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        _snack(mensajeErrorHumano(e));
      }
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }
}

/// Inserta una fila de bitácora (`ticket_eventos`).
Future<void> _evento(dynamic tx, String ticketId, String tenantId,
    String tipoEvento, String? estadoAnt, String? estadoNue, String? hechoPor,
    String ocurrido, String now,
    {String? comentario}) async {
  await tx.execute(
    '''INSERT INTO ticket_eventos
       (id, tenant_id, ticket_id, tipo_evento, estado_anterior, estado_nuevo,
        comentario, hecho_por, ocurrido_en, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
    [
      const Uuid().v4(), tenantId, ticketId, tipoEvento, estadoAnt, estadoNue,
      comentario, hechoPor, ocurrido, now,
    ],
  );
}

/// Búsqueda de cliente (opcional) para asociar al ticket.
class _ClienteSearchSheet extends StatefulWidget {
  const _ClienteSearchSheet();
  @override
  State<_ClienteSearchSheet> createState() => _ClienteSearchSheetState();
}

class _ClienteSearchSheetState extends State<_ClienteSearchSheet> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final like = '%${_q.toLowerCase()}%';
    final stream = ps.db.watch(
      '''SELECT id, nombre, codigo FROM clientes
          WHERE activo = 1 AND (
                lower(nombre) LIKE ?
             OR lower(coalesce(codigo, '')) LIKE ?
             OR lower(coalesce(cedula, '')) LIKE ?)
          ORDER BY nombre LIMIT 50''',
      parameters: [like, like, like],
    );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: 16, right: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar por nombre, código o cédula',
              ),
              onChanged: (v) => setState(() => _q = v.trim()),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 320,
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: stream,
                initialData: const [],
                builder: (context, snap) {
                  final rows = snap.data ?? const [];
                  if (rows.isEmpty) {
                    return const Center(child: Text('Sin resultados'));
                  }
                  return ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final c = rows[i];
                      final cod = c['codigo'] as String?;
                      return ListTile(
                        title: Text(c['nombre'] as String),
                        subtitle:
                            cod != null && cod.isNotEmpty ? Text(cod) : null,
                        onTap: () => Navigator.pop(context, (
                          id: c['id'] as String,
                          nombre: c['nombre'] as String,
                        )),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
