import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/ticket_sla.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_cambios_widget.dart';
import '../../shared/widgets/ticket_sla_countdown.dart';
import 'ticket_adjuntos_widget.dart';
import 'ticket_materiales_widget.dart';

/// Detalle de un ticket: header (estado/SLA/tipo/cliente/asignado), acciones de
/// transición de estado (válidas según el estado actual; el server re-valida),
/// reasignar, comentar, y la bitácora (`ticket_eventos`).
///
/// `tecnicoMode`: vista del técnico en campo (Fase 3B). Acota lo que se OFRECE —
/// sólo avanzar/pausar/resolver ([kEstadosDestinoTecnico]) y SIN reasignar. El
/// admin (modo normal) tiene todas las transiciones + reasignar.
class TicketDetailScreen extends ConsumerStatefulWidget {
  const TicketDetailScreen({
    super.key,
    required this.ticketId,
    this.tecnicoMode = false,
  });
  final String ticketId;
  final bool tecnicoMode;
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
             cl.nombre AS cliente_nombre, co.nombre AS asignado_nombre,
             inc.titulo AS incidente_titulo
        FROM tickets t
   LEFT JOIN ticket_tipos tt ON tt.id = t.tipo_id
   LEFT JOIN clientes cl ON cl.id = t.cliente_id
   LEFT JOIN cobradores co ON co.id = t.asignado_a
   LEFT JOIN incidentes inc ON inc.id = t.incidente_id
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
    // SLA por prioridad se lee acá (build del Consumer), no dentro del builder
    // del StreamBuilder (que puede reconstruirse solo). Se pasa a _header.
    final slaMap = ref.watch(appSettingsProvider).slaHorasPorPrioridad;
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
                _header(context, t, slaMap),
                const SizedBox(height: 8),
                _acciones(context, t),
                const SizedBox(height: 16),
                _checklistSection(context, t),
                _comentarRow(context, t),
                const SizedBox(height: 16),
                TicketAdjuntosWidget(
                    ticketId: widget.ticketId,
                    tenantId: t['tenant_id'] as String),
                const SizedBox(height: 16),
                // Materiales consumidos (Fase 3C) — visible si el tenant tiene
                // el módulo inventario. El técnico consume de su custodia.
                TicketMaterialesWidget(
                    ticketId: widget.ticketId,
                    tenantId: t['tenant_id'] as String,
                    clienteId: t['cliente_id'] as String?,
                    tecnicoMode: widget.tecnicoMode),
                const SizedBox(height: 16),
                _timeline(context),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(
      BuildContext context, Map<String, dynamic> t, Map<String, int> slaMap) {
    final scheme = Theme.of(context).colorScheme;
    final estado = t['estado'] as String? ?? 'abierto';
    final prioridad = t['prioridad'] as String?;
    final createdAt = parseTicketWallClock(t['created_at'] as String);
    final pausado = (t['segundos_pausado'] as int?) ?? 0;
    // SLA EFECTIVO = min(SLA del tipo, SLA de la prioridad). El chip muestra la
    // cuenta regresiva viva (tick 1s en el detalle).
    final ef = slaHorasEfectivas(t['sla_horas'] as int?, slaMap[prioridad]);
    final sla = ticketSlaEstado(
      estado: estado,
      createdAt: createdAt,
      slaHoras: ef,
      prioridad: prioridad,
      segundosPausado: pausado,
    );
    final viva = sla == SlaEstado.enPlazo ||
        sla == SlaEstado.porVencer ||
        sla == SlaEstado.vencido;
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
                TicketSlaCountdown(
                  estado: estado,
                  createdAt: createdAt,
                  slaHoras: ef,
                  prioridad: prioridad,
                  segundosPausado: pausado,
                  tick: const Duration(seconds: 1),
                ),
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
            // Incidente vinculado (sólo el admin sincroniza incidentes → para el
            // técnico viene null y no se muestra).
            if (t['incidente_titulo'] != null)
              _row(context, Icons.cell_tower, 'Incidente',
                  t['incidente_titulo'] as String?),
            _row(context, Icons.schedule, 'Creado',
                Fmt.fechaCorta(createdAt.toLocal())),
            // Vencimiento del SLA (sólo con cuenta regresiva viva; en espera el
            // plazo se corre, así que no mostramos una fecha que cambiaría).
            if (viva && ef != null)
              _row(context, Icons.timer_outlined, 'Vence',
                  _fmtVence(createdAt, ef, pausado)),
          ],
        ),
      ),
    );
  }

  // Chip compacto reutilizado en el header (estado / prioridad).
  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );

  // Fila ícono + label + valor. Se oculta si el valor es vacío/null.
  Widget _row(BuildContext context, IconData icon, String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.outline),
          const SizedBox(width: 12),
          SizedBox(
              width: 90,
              child: Text(label, style: TextStyle(color: scheme.outline))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  // Fecha/hora local del vencimiento del SLA: created_at + sla efectivo + pausa.
  String _fmtVence(DateTime createdAt, int slaHoras, int segundosPausado) {
    final d = createdAt
        .add(Duration(hours: slaHoras))
        .add(Duration(seconds: segundosPausado))
        .toLocal();
    return '${Fmt.fechaCorta(d)} ${Fmt.hora(d)}';
  }

  // Checklist del ticket (snapshot del template del tipo). El técnico/admin tilda
  // los pasos; se guarda como JSONB en tickets.checklist. No renderiza si está vacío.
  Widget _checklistSection(BuildContext context, Map<String, dynamic> t) {
    final lista = _parseChecklist(t['checklist']);
    if (lista.isEmpty) return const SizedBox.shrink();
    final hechos = lista.where((e) => e['hecho'] == true).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Checklist',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  Text('$hechos/${lista.length}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline)),
                ],
              ),
            ),
            for (int i = 0; i < lista.length; i++)
              CheckboxListTile(
                dense: true,
                value: lista[i]['hecho'] == true,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text('${lista[i]['texto'] ?? ''}'),
                onChanged: (v) => _toggleChecklist(t, lista, i, v ?? false),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _parseChecklist(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return [
          for (final e in decoded)
            if (e is Map) Map<String, dynamic>.from(e)
        ];
      }
    } catch (_) {}
    return const [];
  }

  Future<void> _toggleChecklist(Map<String, dynamic> t,
      List<Map<String, dynamic>> lista, int index, bool hecho) async {
    if (index < 0 || index >= lista.length) return;
    final nueva = [for (final e in lista) Map<String, dynamic>.from(e)];
    nueva[index]['hecho'] = hecho;
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    try {
      await ps.db.execute(
        'UPDATE tickets SET checklist = ?, ocurrido_en = ? WHERE id = ?',
        [jsonEncode(nueva), ocurrido, t['id']],
      );
    } catch (e) {
      _snack('Error: $e');
    }
  }

  Widget _acciones(BuildContext context, Map<String, dynamic> t) {
    final estado = t['estado'] as String? ?? 'abierto';
    // El técnico sólo avanza/pausa/resuelve; el admin tiene todas las transiciones.
    final transiciones = widget.tecnicoMode
        ? transicionesTecnico(estado)
        : transicionesDesde(estado);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ...transiciones.map((to) => OutlinedButton(
              onPressed: () => _cambiarEstadoConfirmando(t, to),
              child: Text(estadoTicketLabel(to)),
            )),
        // Reasignar: sólo el admin (no el técnico) y no en estados terminales.
        if (!widget.tecnicoMode && estado != 'cerrado' && estado != 'cancelado')
          TextButton.icon(
            icon: const Icon(Icons.engineering, size: 18),
            label: const Text('Reasignar'),
            onPressed: () => _reasignar(t),
          ),
        // Vincular a un incidente/outage abierto (sólo admin). El flujo real es
        // tickets-primero → el admin declara el corte → agrupa los tickets.
        if (!widget.tecnicoMode)
          TextButton.icon(
            icon: const Icon(Icons.cell_tower, size: 18),
            label: const Text('Incidente'),
            onPressed: () => _vincularIncidente(t),
          ),
      ],
    );
  }

  Future<void> _vincularIncidente(Map<String, dynamic> t) async {
    final incidentes = await ps.db.getAll(
        "SELECT id, titulo FROM incidentes WHERE estado = 'abierto' ORDER BY inicio DESC");
    if (!mounted) return;
    if (incidentes.isEmpty) {
      _snack('No hay incidentes abiertos para vincular.');
      return;
    }
    final actual = t['incidente_id'] as String?;
    final elegido = await showModalBottomSheet<({String? id})>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('— Sin incidente —'),
              selected: actual == null,
              onTap: () => Navigator.pop(context, (id: null)),
            ),
            ...incidentes.map((i) => ListTile(
                  leading: const Icon(Icons.cell_tower),
                  title: Text(i['titulo'] as String),
                  selected: actual == i['id'],
                  onTap: () =>
                      Navigator.pop(context, (id: i['id'] as String?)),
                )),
          ],
        ),
      ),
    );
    if (elegido == null || elegido.id == actual) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    final nombreInc = elegido.id == null
        ? null
        : incidentes.firstWhere((i) => i['id'] == elegido.id)['titulo'] as String;
    try {
      await ps.db.writeTransaction((tx) async {
        await tx.execute(
          'UPDATE tickets SET incidente_id = ?, ocurrido_en = ? WHERE id = ?',
          [elegido.id, ocurrido, t['id']],
        );
        await _evento(tx, t['id'] as String, tenantId, 'comentario', null, null,
            hechoPor, ocurrido, now,
            comentario: elegido.id == null
                ? 'Desvinculado del incidente'
                : 'Vinculado al incidente: $nombreInc');
      });
    } catch (e) {
      _snack('Error: $e');
    }
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

  void _showHistorialCambios(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.history),
                  const SizedBox(width: 8),
                  Text('Historial de cambios del ticket',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                // Agregador: ticket + adjuntos + materiales en una timeline
                // (patrón cuota/cliente). La bitácora narra los eventos aparte.
                child: HistorialTicketWidget(ticketId: widget.ticketId),
              ),
            ),
          ],
        ),
      ),
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
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Bitácora',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    // M9: la bitácora (ticket_eventos) es el log de dominio; este
                    // botón abre el change-log de campo (audit_log) del ticket.
                    // El técnico no sincroniza audit_log → el sheet saldría vacío,
                    // así que solo se lo mostramos a admin/super.
                    if (!widget.tecnicoMode)
                      IconButton(
                        icon: const Icon(Icons.history, size: 20),
                        tooltip: 'Historial de cambios',
                        onPressed: () => _showHistorialCambios(context),
                      ),
                  ],
                ),
              ),
              ...rows.map((e) {
                final tipo = e['tipo_evento'] as String? ?? '';
                final ant = e['estado_anterior'] as String?;
                final nue = e['estado_nuevo'] as String?;
                final com = e['comentario'] as String?;
                // hecho_por NULL = evento del sistema (ej. auto-cierre del cron);
                // autor null con hecho_por seteado = persona desconocida (sin sync).
                final autor = e['autor'] as String? ??
                    (e['hecho_por'] == null ? 'Sistema' : '—');
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

  /// M16 (audit UX): las transiciones TERMINALES para el rol confirman —
  /// el técnico no puede volver de 'resuelto' (reabrir es del admin) y los
  /// botones del Wrap son contiguos (guantes/sol → tap equivocado).
  Future<void> _cambiarEstadoConfirmando(
      Map<String, dynamic> t, String to) async {
    final terminales = widget.tecnicoMode
        ? const {'resuelto'}
        : const {'cancelado', 'cerrado'};
    if (terminales.contains(to)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('¿Marcar como "${estadoTicketLabel(to)}"?'),
          content: Text(widget.tecnicoMode
              ? 'No vas a poder volverlo a "En progreso": si falta algo, '
                  'tendrá que reabrirlo el administrador.'
              : 'Es un estado terminal del ticket.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Volver'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _cambiarEstado(t, to);
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
