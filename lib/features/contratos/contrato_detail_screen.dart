import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/pago.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/historial_cambios_widget.dart';

// ---------------------------------------------------------------------------
// ContratoDetailScreen — detalle de contrato con cuotas y pagos.
// ---------------------------------------------------------------------------

class ContratoDetailScreen extends ConsumerStatefulWidget {
  const ContratoDetailScreen({super.key, required this.contratoId});
  final String contratoId;

  @override
  ConsumerState<ContratoDetailScreen> createState() =>
      _ContratoDetailScreenState();
}

class _ContratoDetailScreenState extends ConsumerState<ContratoDetailScreen> {
  // --- streams (late final + didUpdateWidget defensivo) ---
  late Stream<List<Map<String, dynamic>>> _contratoStream;
  late Stream<List<Map<String, dynamic>>> _cuotasStream;
  late Stream<List<Map<String, dynamic>>> _pagosStream;
  // Stream para el resumen — agrega SUM de todos los pagos NO anulados del
  // contrato (incluye pagos a cuotas regulares Y a cargos manuales).
  late Stream<List<Map<String, dynamic>>> _resumenStream;

  // --- multi-select ---
  final Set<String> _selected = {};
  _CuotaFiltro _filtro = _CuotaFiltro.todas;

  @override
  void initState() {
    super.initState();
    _contratoStream = _buildContratoStream();
    _cuotasStream = _buildCuotasStream();
    _pagosStream = _buildPagosStream();
    _resumenStream = _buildResumenStream();
  }

  @override
  void didUpdateWidget(ContratoDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.contratoId != widget.contratoId) {
      setState(() {
        _contratoStream = _buildContratoStream();
        _cuotasStream = _buildCuotasStream();
        _pagosStream = _buildPagosStream();
        _resumenStream = _buildResumenStream();
        _selected.clear();
      });
    }
  }

  // --- stream builders ---

  Stream<List<Map<String, dynamic>>> _buildContratoStream() {
    return ps.db.watch(
      '''
      SELECT ct.id, ct.dia_pago, ct.fecha_inicio, ct.fecha_fin,
             ct.estado, ct.cliente_id, ct.cobrador_id,
             p.nombre AS plan_nombre, p.precio_mensual,
             c.nombre AS cliente_nombre
        FROM contratos ct
        JOIN planes  p ON p.id = ct.plan_id
        JOIN clientes c ON c.id = ct.cliente_id
       WHERE ct.id = ?
       LIMIT 1
      ''',
      parameters: [widget.contratoId],
    ).asBroadcastStream();
  }

  Stream<List<Map<String, dynamic>>> _buildCuotasStream() {
    return ps.db.watch(
      '''
      SELECT cu.id, cu.monto, cu.monto_pagado, cu.fecha_vencimiento,
             cu.periodo, cu.estado, cu.contrato_id,
             cu.descripcion, cu.tipo_cargo_manual
        FROM cuotas cu
       WHERE cu.contrato_id = ?
       ORDER BY cu.periodo ASC
      ''',
      parameters: [widget.contratoId],
    ).asBroadcastStream();
  }

  Stream<List<Map<String, dynamic>>> _buildPagosStream() {
    return ps.db.watch(
      '''
      SELECT pa.*, cu.periodo
        FROM pagos pa
        JOIN cuotas cu ON cu.id = pa.cuota_id
       WHERE cu.contrato_id = ?
       ORDER BY pa.fecha_pago DESC
       LIMIT 20
      ''',
      parameters: [widget.contratoId],
    ).asBroadcastStream();
  }

  // Resumen: SUM(monto_pagado) de pagos NO anulados del contrato.
  // Incluye pagos a cuotas regulares Y a cargos manuales del mismo contrato.
  Stream<List<Map<String, dynamic>>> _buildResumenStream() {
    return ps.db.watch(
      '''
      SELECT COALESCE(SUM(pa.monto_cordobas), 0) AS recaudado
        FROM pagos pa
        JOIN cuotas cu ON cu.id = pa.cuota_id
       WHERE cu.contrato_id = ?
         AND pa.anulado = 0
      ''',
      parameters: [widget.contratoId],
    ).asBroadcastStream();
  }

  // --- multi-select helpers ---

  void _toggleSelect(String cuotaId, List<String> orderedPendingIds) {
    setState(() {
      if (_selected.contains(cuotaId)) {
        // Al deseleccionar, quitar esta y todas las posteriores.
        final idx = orderedPendingIds.indexOf(cuotaId);
        for (var i = idx; i < orderedPendingIds.length; i++) {
          _selected.remove(orderedPendingIds[i]);
        }
      } else {
        // Solo permitir seleccionar si es la primera o la anterior ya
        // está seleccionada (consecutivas desde la más vieja).
        final idx = orderedPendingIds.indexOf(cuotaId);
        if (idx == 0 || (idx > 0 && _selected.contains(orderedPendingIds[idx - 1]))) {
          _selected.add(cuotaId);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Debes cobrar las cuotas anteriores primero'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    });
  }

  void _clearSelection() {
    setState(() => _selected.clear());
  }

  // --- estado del contrato ---

  Future<void> _cambiarEstado(String nuevoEstado) async {
    await ps.db.execute(
      'UPDATE contratos SET estado = ? WHERE id = ?',
      [nuevoEstado, widget.contratoId],
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Estado cambiado a $nuevoEstado')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esAdmin = cobrador != null &&
        (cobrador.esAdmin || cobrador.esAdminCobranza || cobrador.esSuperAdmin);
    final settings = ref.watch(appSettingsProvider);
    final multiCuotaEnabled = settings.pagoAdelantadoPermitido;
    final diasGracia = settings.diasGracia;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Detalle del contrato'),
        actions: [
          if (esAdmin)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Historial de cambios',
              onPressed: () => _showChangeLog(context),
            ),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _contratoStream,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final rows = snap.data!;
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.assignment_outlined,
              titulo: 'Contrato no encontrado',
            );
          }
          final contrato = rows.first;

          return Stack(
            children: [
              ListView(
                padding: EdgeInsets.only(
                  left: 16, right: 16, top: 16,
                  bottom: _selected.isNotEmpty ? 96 : 16,
                ),
                children: [
                  _ContratoHeader(
                    contrato: contrato,
                    esAdmin: esAdmin,
                    onEstadoChanged: esAdmin ? _cambiarEstado : null,
                    resumenStream: _resumenStream,
                  ),
                  const SizedBox(height: 24),
                  _CuotasSection(
                    cuotasStream: _cuotasStream,
                    diasGracia: diasGracia,
                    multiSelect: multiCuotaEnabled,
                    selected: _selected,
                    filtro: _filtro,
                    onFiltroChanged: (f) {
                      setState(() => _filtro = f);
                      _clearSelection();
                    },
                    onToggle: _toggleSelect,
                    onTapCuota: (cuotaId) => context.push('/cobro/$cuotaId'),
                    onLongPressCuota: multiCuotaEnabled
                        ? (cuotaId, orderedIds) =>
                            _toggleSelect(cuotaId, orderedIds)
                        : null,
                  ),
                  const SizedBox(height: 24),
                  _PagosSection(pagosStream: _pagosStream),
                ],
              ),
              // FAB multi-cobro
              if (_selected.isNotEmpty)
                Positioned(
                  left: 16, right: 16, bottom: 16,
                  child: Row(
                    children: [
                      IconButton.filledTonal(
                        icon: const Icon(Icons.close),
                        onPressed: _clearSelection,
                        tooltip: 'Cancelar selección',
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          icon: const Icon(Icons.payment),
                          label: Text(_selected.length == 1
                              ? 'Cobrar cuota'
                              : 'Cobrar ${_selected.length} cuotas'),
                          onPressed: () {
                            final ids = _selected.join(',');
                            _clearSelection();
                            context.push('/cobro/$ids');
                          },
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _showChangeLog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, ctrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Historial de cambios',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                controller: ctrl,
                child: HistorialCambiosWidget(
                  tabla: 'contratos',
                  registroId: widget.contratoId,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header del contrato
// ---------------------------------------------------------------------------

class _ContratoHeader extends StatelessWidget {
  const _ContratoHeader({
    required this.contrato,
    required this.esAdmin,
    required this.resumenStream,
    this.onEstadoChanged,
  });
  final Map<String, dynamic> contrato;
  final bool esAdmin;
  final Stream<List<Map<String, dynamic>>> resumenStream;
  final ValueChanged<String>? onEstadoChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final estado = contrato['estado'] as String? ?? 'activo';
    final planNombre = contrato['plan_nombre'] as String? ?? '—';
    final precio = (contrato['precio_mensual'] as num?)?.toDouble() ?? 0;
    final fechaInicio = DateTime.parse(contrato['fecha_inicio'] as String);
    final fechaFin = contrato['fecha_fin'] != null
        ? DateTime.parse(contrato['fecha_fin'] as String)
        : null;
    final diaPago = contrato['dia_pago'] as int? ?? 1;
    final clienteNombre = contrato['cliente_nombre'] as String? ?? '—';

    final (Color badgeColor, String badgeLabel) = switch (estado) {
      'activo' => (scheme.primary, 'Activo'),
      'completado' => (Colors.green, 'Completado'),
      'cancelado' => (scheme.error, 'Cancelado'),
      _ => (scheme.outline, estado),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Fila: plan + badge estado
            Row(
              children: [
                Icon(Icons.assignment, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    planNombre,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                if (esAdmin && onEstadoChanged != null)
                  PopupMenuButton<String>(
                    tooltip: 'Cambiar estado',
                    onSelected: onEstadoChanged,
                    itemBuilder: (_) => [
                      if (estado != 'activo')
                        const PopupMenuItem(
                            value: 'activo', child: Text('Activo')),
                      if (estado != 'cancelado')
                        const PopupMenuItem(
                            value: 'cancelado', child: Text('Cancelado')),
                      if (estado != 'completado')
                        const PopupMenuItem(
                            value: 'completado', child: Text('Completado')),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(badgeLabel,
                              style: TextStyle(
                                color: badgeColor,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              )),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_drop_down,
                              size: 18, color: badgeColor),
                        ],
                      ),
                    ),
                  )
                else
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(badgeLabel,
                        style: TextStyle(
                          color: badgeColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        )),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // Cliente
            Row(
              children: [
                Icon(Icons.person, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text(clienteNombre,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 8),
            // Precio
            Row(
              children: [
                Icon(Icons.monetization_on, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text('${Fmt.cordobas(precio)} / mes',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    )),
              ],
            ),
            const Divider(height: 20),
            // Detalle inferior — fila 1: fechas + día pago
            Row(
              children: [
                _DetailChip(
                  icon: Icons.calendar_today,
                  label: 'Inicio',
                  value: Fmt.fechaCorta(fechaInicio),
                ),
                const SizedBox(width: 16),
                _DetailChip(
                  icon: Icons.event,
                  label: 'Fin',
                  value: fechaFin != null ? Fmt.fechaCorta(fechaFin) : 'Indefinido',
                ),
                const SizedBox(width: 16),
                _DetailChip(
                  icon: Icons.today,
                  label: 'Día de pago',
                  value: '$diaPago',
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Resumen financiero del contrato.
            // Total = precio_mensual × meses (lo definido al crear).
            // Recaudado = SUM(pagos no anulados) del contrato.
            // Pendiente = Total - Recaudado.
            _ContratoResumen(
              resumenStream: resumenStream,
              precioMensual: precio,
              fechaInicio: fechaInicio,
              fechaFin: fechaFin,
            ),
          ],
        ),
      ),
    );
  }

  static String _duracionLabel(DateTime inicio, DateTime? fin) {
    if (fin == null) return 'Indefinido';
    final meses = (fin.year - inicio.year) * 12 + (fin.month - inicio.month);
    if (meses <= 0) return '—';
    if (meses == 1) return '1 mes';
    if (meses == 12) return '1 año';
    if (meses == 24) return '2 años';
    if (meses % 12 == 0) return '${meses ~/ 12} años';
    return '$meses meses';
  }
}

// ---------------------------------------------------------------------------
// Resumen financiero del contrato
// ---------------------------------------------------------------------------

class _ContratoResumen extends StatelessWidget {
  const _ContratoResumen({
    required this.resumenStream,
    required this.precioMensual,
    required this.fechaInicio,
    required this.fechaFin,
  });
  final Stream<List<Map<String, dynamic>>> resumenStream;
  final double precioMensual;
  final DateTime fechaInicio;
  final DateTime? fechaFin;

  /// Total contrato = precio_mensual × meses (definido al crear).
  /// Para contratos indefinidos retorna null.
  double? _calcularTotalContrato() {
    if (fechaFin == null) return null;
    final meses = (fechaFin!.year - fechaInicio.year) * 12 +
        (fechaFin!.month - fechaInicio.month);
    if (meses <= 0) return null;
    return precioMensual * meses;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totalContrato = _calcularTotalContrato();
    final esIndefinido = totalContrato == null;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: resumenStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) return const SizedBox.shrink();
        final rows = snap.data!;
        final recaudado = rows.isEmpty
            ? 0.0
            : ((rows.first['recaudado'] as num?) ?? 0).toDouble();
        final pendiente =
            esIndefinido ? 0.0 : (totalContrato - recaudado).clamp(0, double.infinity).toDouble();

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (esIndefinido) ...[
                Expanded(
                  child: _ResumenItem(
                    label: 'Total recaudado',
                    value: Fmt.cordobas(recaudado),
                    color: Colors.green.shade700,
                  ),
                ),
              ] else ...[
                Expanded(
                  child: _ResumenItem(
                    label: 'Total contrato',
                    value: Fmt.cordobas(totalContrato),
                    color: scheme.onSurface,
                  ),
                ),
                Container(
                    width: 1, height: 36, color: scheme.outline.withValues(alpha: 0.3)),
                Expanded(
                  child: _ResumenItem(
                    label: 'Recaudado',
                    value: Fmt.cordobas(recaudado),
                    color: Colors.green.shade700,
                  ),
                ),
                Container(
                    width: 1, height: 36, color: scheme.outline.withValues(alpha: 0.3)),
                Expanded(
                  child: _ResumenItem(
                    label: 'Pendiente',
                    value: Fmt.cordobas(pendiente),
                    color: pendiente > 0 ? scheme.error : scheme.outline,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ResumenItem extends StatelessWidget {
  const _ResumenItem({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label,
            style: TextStyle(fontSize: 10, color: scheme.outline),
            textAlign: TextAlign.center),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: 13, color: color),
            textAlign: TextAlign.center),
      ],
    );
  }
}

class _DetailChip extends StatelessWidget {
  const _DetailChip({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: scheme.outline),
              const SizedBox(width: 4),
              Flexible(
                child: Text(label,
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Seccion de cuotas
// ---------------------------------------------------------------------------

enum _CuotaFiltro { todas, pendientes, pagadas }

class _CuotasSection extends StatelessWidget {
  const _CuotasSection({
    required this.cuotasStream,
    required this.diasGracia,
    required this.multiSelect,
    required this.selected,
    required this.filtro,
    required this.onFiltroChanged,
    required this.onToggle,
    required this.onTapCuota,
    this.onLongPressCuota,
  });
  final Stream<List<Map<String, dynamic>>> cuotasStream;
  final int diasGracia;
  final bool multiSelect;
  final Set<String> selected;
  final _CuotaFiltro filtro;
  final ValueChanged<_CuotaFiltro> onFiltroChanged;
  final void Function(String cuotaId, List<String> orderedPendingIds) onToggle;
  final ValueChanged<String> onTapCuota;
  final void Function(String cuotaId, List<String> orderedIds)? onLongPressCuota;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Titulo
        Row(
          children: [
            Icon(Icons.receipt_long, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text('Cuotas',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 8),
        // Filter chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final f in _CuotaFiltro.values) ...[
                FilterChip(
                  label: Text(_filtroLabel(f)),
                  selected: filtro == f,
                  onSelected: (_) => onFiltroChanged(f),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Stream de cuotas
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: cuotasStream,
          initialData: const [],
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(child: Text('Error: ${snap.error}'));
            }
            final allRows = snap.data!;

            // Filtrar segun chip activo
            final rows = allRows.where((r) {
              final estado = r['estado'] as String? ?? 'pendiente';
              return switch (filtro) {
                _CuotaFiltro.todas => true,
                _CuotaFiltro.pendientes =>
                  estado == 'pendiente' || estado == 'parcial',
                _CuotaFiltro.pagadas => estado == 'pagada',
              };
            }).toList();

            if (rows.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('Sin cuotas',
                      style: TextStyle(color: scheme.outline)),
                ),
              );
            }

            // IDs pendientes ordenados para validar orden de seleccion.
            final pendingIds = allRows
                .where((r) {
                  final e = r['estado'] as String? ?? '';
                  return e == 'pendiente' || e == 'parcial';
                })
                .map((r) => r['id'] as String)
                .toList();

            return Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _CuotaRow(
                      row: rows[i],
                      diasGracia: diasGracia,
                      isSelected: selected.contains(rows[i]['id'] as String),
                      showCheckbox: selected.isNotEmpty,
                      onTap: () {
                        final cuotaId = rows[i]['id'] as String;
                        final estado = rows[i]['estado'] as String? ?? '';
                        if (selected.isNotEmpty && pendingIds.contains(cuotaId)) {
                          onToggle(cuotaId, pendingIds);
                        } else if (selected.isEmpty &&
                            (estado == 'pendiente' || estado == 'parcial')) {
                          onTapCuota(cuotaId);
                        }
                      },
                      onLongPress: multiSelect &&
                              _isPending(rows[i]['estado'] as String? ?? '')
                          ? () {
                              final cuotaId = rows[i]['id'] as String;
                              if (onLongPressCuota != null) {
                                onLongPressCuota!(cuotaId, pendingIds);
                              }
                            }
                          : null,
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  static bool _isPending(String estado) =>
      estado == 'pendiente' || estado == 'parcial';

  static String _filtroLabel(_CuotaFiltro f) => switch (f) {
        _CuotaFiltro.todas => 'Todas',
        _CuotaFiltro.pendientes => 'Pendientes',
        _CuotaFiltro.pagadas => 'Pagadas',
      };
}

// ---------------------------------------------------------------------------
// Fila compacta de cuota (con color bar)
// ---------------------------------------------------------------------------

class _CuotaRow extends StatelessWidget {
  const _CuotaRow({
    required this.row,
    required this.diasGracia,
    required this.isSelected,
    required this.showCheckbox,
    required this.onTap,
    this.onLongPress,
  });
  final Map<String, dynamic> row;
  final int diasGracia;
  final bool isSelected;
  final bool showCheckbox;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final estado = row['estado'] as String? ?? 'pendiente';
    final monto = (row['monto'] as num? ?? 0).toDouble();
    final montoPagado = (row['monto_pagado'] as num? ?? 0).toDouble();
    final saldo = monto - montoPagado;
    final periodo = DateTime.parse(row['periodo'] as String);
    final vence = DateTime.parse(row['fecha_vencimiento'] as String);

    final hoy = DateTime.now();
    final diasFromVence =
        DateTime(hoy.year, hoy.month, hoy.day)
            .difference(DateTime(vence.year, vence.month, vence.day))
            .inDays;

    // Color coding segun estado
    final (String label, Color color) = switch (estado) {
      'pagada' => ('Pagada', Colors.green),
      'anulada' => ('Anulada', Colors.grey),
      'parcial' when diasFromVence > diasGracia =>
        ('Vencida ${diasFromVence - diasGracia}d', scheme.error),
      'parcial' when diasFromVence > 0 =>
        ('Gracia (parcial)', Colors.amber.shade700),
      'parcial' => ('Parcial', scheme.primary),
      'pendiente' when diasFromVence > diasGracia =>
        ('Vencida ${diasFromVence - diasGracia}d', scheme.error),
      'pendiente' when diasFromVence > 0 =>
        ('Gracia', Colors.amber.shade700),
      'pendiente' when diasFromVence == 0 => ('Hoy', scheme.primary),
      'pendiente' => ('${-diasFromVence}d', scheme.outline),
      _ => (estado, scheme.outline),
    };

    final mesLabel =
        '${Fmt.mes(periodo)[0].toUpperCase()}${Fmt.mes(periodo).substring(1)}';
    final esPagadaOAnulada = estado == 'pagada' || estado == 'anulada';

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: isSelected
            ? scheme.primaryContainer.withValues(alpha: 0.3)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Checkbox o color bar
            if (showCheckbox)
              Checkbox(
                value: isSelected,
                onChanged: (_) => onTap(),
                visualDensity: VisualDensity.compact,
              )
            else
              SizedBox(
                width: 8,
                child: Container(
                  width: 4,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            const SizedBox(width: 8),
            // Mes + fecha vencimiento
            SizedBox(
              width: 100,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mesLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: esPagadaOAnulada ? scheme.outline : null,
                      )),
                  Text(Fmt.fechaCorta(vence),
                      style: TextStyle(fontSize: 10, color: scheme.outline)),
                ],
              ),
            ),
            // Estado badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(label,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  )),
            ),
            const Spacer(),
            // Monto
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  Fmt.cordobas(esPagadaOAnulada ? monto : saldo),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: esPagadaOAnulada ? scheme.outline : null,
                    decoration:
                        estado == 'anulada' ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (montoPagado > 0 && estado == 'parcial')
                  Text(
                    'pagado ${Fmt.cordobas(montoPagado)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.green.shade700,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Seccion de pagos recientes
// ---------------------------------------------------------------------------

class _PagosSection extends StatelessWidget {
  const _PagosSection({required this.pagosStream});
  final Stream<List<Map<String, dynamic>>> pagosStream;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.payments, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text('Pagos recientes',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 8),
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: pagosStream,
          initialData: const [],
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(child: Text('Error: ${snap.error}'));
            }
            final rows = snap.data!;
            if (rows.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('Sin pagos registrados',
                      style: TextStyle(color: scheme.outline)),
                ),
              );
            }

            return Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _PagoTile(row: rows[i]),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _PagoTile extends StatelessWidget {
  const _PagoTile({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pago = Pago.fromRow(row);
    final periodo = row['periodo'] != null
        ? DateTime.parse(row['periodo'] as String)
        : null;

    final metodoLabel = pago.metodo.label;
    final montoLabel = pago.moneda == Moneda.nio
        ? Fmt.cordobas(pago.montoCordobas)
        : '${Fmt.dolares(pago.montoOriginal)} (${Fmt.cordobas(pago.montoCordobas)})';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // Icono
          Icon(
            pago.anulado ? Icons.block : Icons.check_circle,
            size: 20,
            color: pago.anulado ? scheme.error : Colors.green,
          ),
          const SizedBox(width: 10),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  periodo != null
                      ? '${Fmt.mes(periodo)[0].toUpperCase()}${Fmt.mes(periodo).substring(1)}'
                      : '—',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                    decoration:
                        pago.anulado ? TextDecoration.lineThrough : null,
                  ),
                ),
                Text(
                  '${Fmt.fechaCorta(pago.fechaPago)} · $metodoLabel',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
            ),
          ),
          // Monto
          Text(
            montoLabel,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: pago.anulado ? scheme.error : null,
              decoration: pago.anulado ? TextDecoration.lineThrough : null,
            ),
          ),
        ],
      ),
    );
  }
}
