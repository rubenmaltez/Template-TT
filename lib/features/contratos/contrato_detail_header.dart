part of 'contrato_detail_screen.dart';

String _duracionLabelHelper(DateTime inicio, DateTime? fin) {
  if (fin == null) return 'Indefinido';
  final meses = (fin.year - inicio.year) * 12 + (fin.month - inicio.month);
  if (meses <= 0) return '—';
  if (meses == 1) return '1 mes';
  if (meses == 12) return '1 año';
  if (meses == 24) return '2 años';
  if (meses % 12 == 0) return '${meses ~/ 12} años';
  return '$meses meses';
}

class _ContratoHeader extends StatelessWidget {
  const _ContratoHeader({
    required this.contrato,
    required this.esAdmin,
    required this.contratoId,
    this.onEstadoChanged,
  });
  final Map<String, dynamic> contrato;
  final bool esAdmin;
  final String contratoId;
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
            // Duración (legible: 1 año / 2 años / N meses / Indefinido)
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.timelapse, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text('Duración: ${_duracionLabelHelper(fechaInicio, fechaFin)}',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
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
              contratoId: contratoId,
              precioMensual: precio,
              fechaInicio: fechaInicio,
              fechaFin: fechaFin,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Resumen financiero del contrato
// ---------------------------------------------------------------------------

class _ContratoResumen extends ConsumerWidget {
  const _ContratoResumen({
    required this.contratoId,
    required this.precioMensual,
    required this.fechaInicio,
    required this.fechaFin,
  });
  final String contratoId;
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
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final totalContrato = _calcularTotalContrato();
    final esIndefinido = totalContrato == null;
    return ref.watch(contratoRecaudadoProvider(contratoId)).when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (rows) {
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

