import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/ticket_sla.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import 'ticket_adjuntos_widget.dart';

/// Detalle de un ticket: header (estado/SLA/tipo/cliente/asignado), acciones de
/// transición de estado (válidas según el estado actual; el server re-valida),
/// reasignar, comentar, y la bitácora (`ticket_eventos`).
class TicketDetailScreen extends ConsumerStatefulWidget {
  const TicketDetailScreen({super.key, required this.ticketId});
  final String ticketId;
  @override
  ConsumerState<TicketDetailScreen> createState() => _TicketDetailScreenState();
}

class _TicketDetailScreenState extends ConsumerState<TicketDetailScreen> {
  late final Stream<List<Map<String, dynamic>>> _ticket;
  late final Stream<List<Map<String, dynamic>>> _eventos;
  final _comentario = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ticket = ps.db.watch('''
      SELECT t.*, tt.nombre AS tipo_nombre, tt.sla_horas,
             cl.nombre AS cliente_nombre, co.nombre AS asignado_nombre
        FROM tickets t
   LEFT JOIN ticket_tipos tt ON tt.id = t.tipo_id
   LEFT JOIN clientes cl ON cl.id = t.cliente_id
   LEFT JOIN cobradores co ON co.id = t.asignado_a
       WHERE t.id = ?
    ''', parameters: [widget.ticketId]);
    _eventos = ps.db.watch('''
      SELECT e.*, c.nombre AS autor
        FROM ticket_eventos e
   LEFT JOIN cobradores c ON c.id = e.hecho_por
       WHERE e.ticket_id = ?
       ORDER BY COALESCE(e.ocurrido_en, e.created_at) DESC
    ''', parameters: [widget.ticketId]);
  }

  @override
  void dispose() {
    _comentario.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _ticket,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
              icon: Icons.confirmation_number_outlined,
              titulo: 'Ticket no encontrado');
        }
        final t = rows.first;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
              children: [
                _header(context, t),
                const SizedBox(height: 8),
                _acciones(context, t),
                const SizedBox(height: 16),
                _comentarRow(context, t),
                const SizedBox(height: 16),
                TicketAdjuntosWidget(
                    ticketId: widget.ticketId,
                    tenantId: t['tenant_id'] as String),
                const SizedBox(height: 16),
                _timeline(context),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, Map<String, dynamic> t) {
    final scheme = Theme.of(context).colorScheme;
    final estado = t['estado'] as String? ?? 'abierto';
    final sla = ticketSlaEstado(
      estado: estado,
      createdAt: DateTime.parse(t['created_at'] as String),
      slaHoras: t['sla_horas'] as int?,
      segundosPausado: (t['segundos_pausado'] as int?) ?? 0,
    );
    final prioridad = t['prioridad'] as String?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ticketCodigo(t['correlativo'] as num?),
                style: TextStyle(
                    color: scheme.primary, fontWeight: FontWeight.w700)),
            Text(t['titulo'] as String,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _chip(estadoTicketLabel(estado), estadoTicketColor(estado, scheme)),
              if (sla != SlaEstado.sinSla && sla != SlaEstado.cerrado)
                _chip(slaLabel(sla), slaColor(sla, scheme)),
              if (prioridad != null)
                _chip(prioridadLabel(prioridad), prioridadColor(prioridad, scheme)),
            ]),
            const SizedBox(height: 12),
            if ((t['descripcion'] as String?)?.isNotEmpty ?? false) ...[
              Text(t['descripcion'] as String),
              const SizedBox(height: 12),
            ],
            _row(context, Icons.label_outline, 'Tipo', t['tipo_nombre'] as String?),
            _row(context, Icons.person, 'Cliente', t['cliente_nombre'] as String?),
            _row(context, Icons.engineering, 'Asignado',
                t['asignado_nombre'] as String?),
            _row(context, Icons.schedule, 'Creado',
                Fmt.fechaCorta(DateTime.parse(t['created_at'] as String).toLocal())),
          ],
        ),
      ),
    );
  }

  Widget _acciones(BuildContext context, Map<String, dynamic> t) {
    final estado = t['estado'] as String? ?? 'abierto';
    final transiciones = transicionesDesde(estado);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ...transiciones.map((to) => OutlinedButton(
              onPressed: () => _cambiarEstado(t, to),
              child: Text(estadoTicketLabel(to)),
            )),
        // Reasignar no tiene sentido en estados terminales (cerrado/cancelado).
        if (estado != 'cerrado' && estado != 'cancelado')
          TextButton.icon(
            icon: const Icon(Icons.engineering, size: 18),
            label: const Text('Reasignar'),
            onPressed: () => _reasignar(t),
          ),
      ],
    );
  }

  Widget _comentarRow(BuildContext context, Map<String, dynamic> t) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _comentario,
            decoration: const InputDecoration(
              labelText: 'Agregar comentario',
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          icon: const Icon(Icons.send),
          onPressed: () => _comentar(t),
        ),
      ],
    );
  }

  Widget _timeline(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _eventos,
      initialData: const [],
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        if (rows.isEmpty) {
          return const SizedBox.shrink();
        }
        return Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text('Bitácora',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              ...rows.map((e) {
                final tipo = e['tipo_evento'] as String? ?? '';
                final ant = e['estado_anterior'] as String?;
                final nue = e['estado_nuevo'] as String?;
                final com = e['comentario'] as String?;
                final autor = e['autor'] as String? ?? '—';
                final fecha = DateTime.parse(
                    (e['ocurrido_en'] ?? e['created_at']) as String).toLocal();
                final detalle = [
                  if (tipo == 'cambio_estado' && ant != null && nue != null)
                    '${estadoTicketLabel(ant)} → ${estadoTicketLabel(nue)}',
                  if (com != null && com.isNotEmpty) com,
                ].join(' · ');
                return ListTile(
                  dense: true,
                  leading: Icon(tipoEventoIcon(tipo),
                      size: 20, color: scheme.outline),
                  title: Text(tipoEventoLabel(tipo),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text([
                    if (detalle.isNotEmpty) detalle,
                    '${Fmt.fechaCorta(fecha)} ${Fmt.hora(fecha)} · $autor',
                  ].join('\n')),
                  isThreeLine: detalle.isNotEmpty,
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // ── Acciones ────────────────────────────────────────────────────────────
  Future<void> _cambiarEstado(Map<String, dynamic> t, String nuevo) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    final anterior = t['estado'] as String? ?? 'abierto';
    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    // Sello de tiempo según el estado destino.
    final extraSet = switch (nuevo) {
      'resuelto' => ', resuelto_en = ?',
      'cerrado' => ', cerrado_en = ?',
      _ => '',
    };
    final tipoEvento = switch (nuevo) {
      'cancelado' => 'cancelado',
      'cerrado' => 'cerrado',
      'reabierto' => 'reabierto',
      _ => 'cambio_estado',
    };
    try {
      await ps.db.writeTransaction((tx) async {
        // Re-validar el estado esperado dentro de la tx (evita pisar un cambio
        // hecho en otra pestaña/device; el trigger del server igual re-valida).
        final cur = await tx.getOptional(
            'SELECT estado FROM tickets WHERE id = ?', [t['id']]);
        if (cur == null || cur['estado'] != anterior) {
          throw _TkError('El ticket cambió de estado; recargá.');
        }
        await tx.execute(
          'UPDATE tickets SET estado = ?, ocurrido_en = ?$extraSet WHERE id = ?',
          extraSet.isEmpty
              ? [nuevo, ocurrido, t['id']]
              : [nuevo, ocurrido, ocurrido, t['id']],
        );
        await _evento(tx, t['id'] as String, tenantId, tipoEvento, anterior,
            nuevo, hechoPor, ocurrido, now);
      });
    } on _TkError catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Error: $e');
    }
  }

  Future<void> _comentar(Map<String, dynamic> t) async {
    final texto = _comentario.text.trim();
    if (texto.isEmpty) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    try {
      await ps.db.writeTransaction((tx) async {
        await _evento(tx, t['id'] as String, tenantId, 'comentario', null, null,
            hechoPor, ocurrido, now, comentario: texto);
      });
      _comentario.clear();
    } catch (e) {
      _snack('Error: $e');
    }
  }

  Future<void> _reasignar(Map<String, dynamic> t) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    final tecnicos = await ps.db.getAll(
        "SELECT id, nombre FROM cobradores WHERE activo = 1 AND rol IN ('tecnico','admin_tickets','admin') ORDER BY nombre");
    if (!mounted) return;
    final elegido = await showModalBottomSheet<({String? id, String nombre})>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.person_off),
              title: const Text('— Sin asignar —'),
              onTap: () => Navigator.pop(context, (id: null, nombre: 'sin asignar')),
            ),
            ...tecnicos.map((c) => ListTile(
                  leading: const Icon(Icons.engineering),
                  title: Text(c['nombre'] as String),
                  onTap: () => Navigator.pop(
                      context, (id: c['id'] as String, nombre: c['nombre'] as String)),
                )),
          ],
        ),
      ),
    );
    if (elegido == null || !mounted) return;
    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    try {
      await ps.db.writeTransaction((tx) async {
        // Re-leer el estado FRESCO dentro de la tx (simetría con _cambiarEstado):
        // computamos nuevoEstado desde el valor real, no del snapshot stale, para
        // no generar una transición inválida que el server rechazaría.
        final cur = await tx.getOptional(
            'SELECT estado FROM tickets WHERE id = ?', [t['id']]);
        final estadoActual = cur?['estado'] as String? ?? 'abierto';
        // Asignar mueve abierto→asignado; en cualquier otro estado solo cambia el
        // responsable (sin tocar el estado, para no romper transiciones).
        final nuevoEstado =
            estadoActual == 'abierto' && elegido.id != null ? 'asignado' : estadoActual;
        await tx.execute(
          'UPDATE tickets SET asignado_a = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
          [elegido.id, nuevoEstado, ocurrido, t['id']],
        );
        await _evento(tx, t['id'] as String, tenantId, 'asignado', estadoActual,
            nuevoEstado, hechoPor, ocurrido, now,
            comentario: elegido.id == null ? 'Sin asignar' : 'Asignado a ${elegido.nombre}');
      });
    } catch (e) {
      _snack('Error: $e');
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }
}

class _TkError implements Exception {
  const _TkError(this.message);
  final String message;
}

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
