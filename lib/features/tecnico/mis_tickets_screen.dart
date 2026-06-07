import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/settings_repo.dart';
import '../../data/utils/ticket_sla.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/ticket_sla_countdown.dart';

/// "Mis tickets" — lista de tickets asignados al técnico (Fase 3B). El SQLite
/// local ya viene acotado por el bucket `por_tecnico_tickets` (sólo los suyos),
/// así que la query no filtra por `asignado_a`: todo lo local es del técnico.
/// Filtro por grupo de estado EN SQL; tap → detalle (`/tecnico/tickets/:id`).
class MisTicketsScreen extends ConsumerStatefulWidget {
  const MisTicketsScreen({super.key});
  @override
  ConsumerState<MisTicketsScreen> createState() => _MisTicketsScreenState();
}

const _grupos = {
  'activos': {'abierto', 'asignado', 'en_progreso', 'en_espera', 'reabierto'},
  'cerrados': {'resuelto', 'cerrado', 'cancelado'},
};

class _MisTicketsScreenState extends ConsumerState<MisTicketsScreen> {
  late Stream<List<Map<String, dynamic>>> _tickets;
  String _filtro = 'activos';

  @override
  void initState() {
    super.initState();
    _tickets = _buildStream();
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    final estados = _grupos[_filtro]!.toList();
    final inClause = List.filled(estados.length, '?').join(', ');
    return ps.db.watch('''
      SELECT t.id, t.correlativo, t.titulo, t.estado, t.prioridad,
             t.cliente_id, t.created_at, t.segundos_pausado,
             tt.nombre AS tipo_nombre, tt.sla_horas,
             cl.nombre AS cliente_nombre
        FROM tickets t
   LEFT JOIN ticket_tipos tt ON tt.id = t.tipo_id
   LEFT JOIN clientes cl ON cl.id = t.cliente_id
       WHERE t.estado IN ($inClause)
       ORDER BY t.created_at DESC
       LIMIT 300
    ''', parameters: estados);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final slaMap = ref.watch(appSettingsProvider).slaHorasPorPrioridad;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              for (final g in const ['activos', 'cerrados'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(g == 'activos' ? 'Activos' : 'Cerrados'),
                    selected: _filtro == g,
                    onSelected: (_) => setState(() {
                      _filtro = g;
                      _tickets = _buildStream();
                    }),
                  ),
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
              final rows = snap.data ?? const [];
              if (rows.isEmpty) {
                return EmptyState(
                  icon: Icons.confirmation_number_outlined,
                  titulo: _filtro == 'activos'
                      ? 'No tenés tickets activos'
                      : 'Sin tickets cerrados',
                  descripcion: _filtro == 'activos'
                      ? 'Cuando el admin te asigne un ticket, aparece acá.'
                      : null,
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = rows[i];
                  final estado = t['estado'] as String? ?? 'abierto';
                  final prioridad = t['prioridad'] as String?;
                  final createdAt = DateTime.parse(t['created_at'] as String);
                  final pausado = (t['segundos_pausado'] as int?) ?? 0;
                  final ef =
                      slaHorasEfectivas(t['sla_horas'] as int?, slaMap[prioridad]);
                  final sla = ticketSlaEstado(
                    estado: estado,
                    createdAt: createdAt,
                    slaHoras: ef,
                    prioridad: prioridad,
                    segundosPausado: pausado,
                  );
                  final cli = t['cliente_nombre'] as String?;
                  final tipo = t['tipo_nombre'] as String?;
                  final sub = [
                    if (tipo != null) tipo,
                    if (cli != null && cli.isNotEmpty) cli,
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
                    subtitle: sub.isEmpty
                        ? null
                        : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing:
                        sla == SlaEstado.sinSla || sla == SlaEstado.cerrado
                            ? Text(estadoTicketLabel(estado),
                                style: TextStyle(
                                    color: estadoTicketColor(estado, scheme),
                                    fontSize: 12))
                            : TicketSlaCountdown(
                                estado: estado,
                                createdAt: createdAt,
                                slaHoras: ef,
                                prioridad: prioridad,
                                segundosPausado: pausado,
                              ),
                    onTap: () => context.push('/tecnico/tickets/${t['id']}'),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
