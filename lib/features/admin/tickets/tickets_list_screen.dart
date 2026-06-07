import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/utils/ticket_sla.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';

/// Lista de tickets del tenant (admin). Filtro por grupo de estado + acceso a
/// los tipos. Tap → detalle. FAB → nuevo ticket.
class TicketsListScreen extends ConsumerStatefulWidget {
  const TicketsListScreen({super.key});
  @override
  ConsumerState<TicketsListScreen> createState() => _TicketsListScreenState();
}

// Grupos de filtro (estado → grupo).
const _grupos = {
  'activos': {'abierto', 'asignado', 'en_progreso', 'en_espera', 'reabierto'},
  'resueltos': {'resuelto', 'cerrado'},
  'cancelados': {'cancelado'},
};

class _TicketsListScreenState extends ConsumerState<TicketsListScreen> {
  late Stream<List<Map<String, dynamic>>> _tickets;
  String _filtro = 'activos';

  @override
  void initState() {
    super.initState();
    _tickets = _buildStream();
  }

  // Filtra por grupo de estado EN SQL (no en memoria) + LIMIT acotado. El stream
  // se recrea al cambiar el filtro.
  Stream<List<Map<String, dynamic>>> _buildStream() {
    final estados = _grupos[_filtro]!.toList();
    final inClause = List.filled(estados.length, '?').join(', ');
    return ps.db.watch('''
      SELECT t.id, t.correlativo, t.titulo, t.estado, t.prioridad,
             t.cliente_id, t.created_at, t.segundos_pausado,
             tt.nombre AS tipo_nombre, tt.sla_horas,
             cl.nombre AS cliente_nombre, co.nombre AS asignado_nombre
        FROM tickets t
   LEFT JOIN ticket_tipos tt ON tt.id = t.tipo_id
   LEFT JOIN clientes cl ON cl.id = t.cliente_id
   LEFT JOIN cobradores co ON co.id = t.asignado_a
       WHERE t.estado IN ($inClause)
       ORDER BY t.created_at DESC
       LIMIT 300
    ''', parameters: estados);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Ticket'),
        onPressed: () => context.push('/admin/tickets/nuevo'),
      ),
      body: Column(
        children: [
          // Filtros + acceso a tipos.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final g in const ['activos', 'resueltos', 'cancelados'])
                        ChoiceChip(
                          label: Text(switch (g) {
                            'activos' => 'Activos',
                            'resueltos' => 'Resueltos',
                            _ => 'Cancelados',
                          }),
                          selected: _filtro == g,
                          onSelected: (_) => setState(() {
                            _filtro = g;
                            _tickets = _buildStream();
                          }),
                        ),
                    ],
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.label_outline, size: 18),
                  label: const Text('Tipos'),
                  onPressed: () => context.push('/admin/tickets/tipos'),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _tickets,
              initialData: const [],
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(child: Text('Error: ${snap.error}'));
                }
                // El filtro por grupo de estado ya se aplicó en SQL (_buildStream).
                final rows = snap.data ?? const [];
                if (rows.isEmpty) {
                  return EmptyState(
                    icon: Icons.confirmation_number_outlined,
                    titulo: 'Sin tickets ${switch (_filtro) {
                      'activos' => 'activos',
                      'resueltos' => 'resueltos',
                      _ => 'cancelados',
                    }}',
                    descripcion: _filtro == 'activos'
                        ? 'Creá un ticket para una instalación, reparación o reclamo.'
                        : null,
                    accion: _filtro == 'activos'
                        ? FilledButton.icon(
                            icon: const Icon(Icons.add),
                            label: const Text('Nuevo ticket'),
                            onPressed: () =>
                                context.push('/admin/tickets/nuevo'),
                          )
                        : null,
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final t = rows[i];
                    final estado = t['estado'] as String? ?? 'abierto';
                    final sla = ticketSlaEstado(
                      estado: estado,
                      createdAt: DateTime.parse(t['created_at'] as String),
                      slaHoras: t['sla_horas'] as int?,
                      segundosPausado: (t['segundos_pausado'] as int?) ?? 0,
                    );
                    final cli = t['cliente_nombre'] as String?;
                    final asig = t['asignado_nombre'] as String?;
                    final tipo = t['tipo_nombre'] as String?;
                    final sub = [
                      if (tipo != null) tipo,
                      if (cli != null && cli.isNotEmpty) cli,
                      if (asig != null && asig.isNotEmpty) '→ $asig',
                    ].join(' · ');
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 6,
                        backgroundColor: estadoTicketColor(estado, scheme),
                      ),
                      title: Text(
                        '${ticketCodigo(t['correlativo'] as num?)} · ${t['titulo']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: sub.isEmpty ? null : Text(sub,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: sla == SlaEstado.sinSla || sla == SlaEstado.cerrado
                          ? Text(estadoTicketLabel(estado),
                              style: TextStyle(
                                  color: estadoTicketColor(estado, scheme),
                                  fontSize: 12))
                          : _SlaChip(sla: sla),
                      onTap: () => context.push('/admin/tickets/${t['id']}'),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SlaChip extends StatelessWidget {
  const _SlaChip({required this.sla});
  final SlaEstado sla;
  @override
  Widget build(BuildContext context) {
    final c = slaColor(sla, Theme.of(context).colorScheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(slaLabel(sla),
          style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}
