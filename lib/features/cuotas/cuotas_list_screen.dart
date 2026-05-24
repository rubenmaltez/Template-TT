import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';

enum _Filtro { todas, mora, gracia, parciales, hoy }

class CuotasListScreen extends ConsumerStatefulWidget {
  const CuotasListScreen({super.key});

  @override
  ConsumerState<CuotasListScreen> createState() => _CuotasListScreenState();
}

class _CuotasListScreenState extends ConsumerState<CuotasListScreen> {
  _Filtro _filtro = _Filtro.todas;

  /// Marca todas las notificaciones de mora sin ver como "vista" cuando
  /// el cobrador abre el filtro "En mora". Esto resetea el badge del
  /// sidebar y le indica al sistema que el cobrador revisó las moras.
  Future<void> _marcarMoraComoVista() async {
    final now = DateTime.now().toUtc().toIso8601String();
    await ps.db.execute('''
      UPDATE notificaciones_mora
      SET vista_en = ?, vista_por = 'cobrador'
      WHERE vista_en IS NULL AND resuelta_en IS NULL
    ''', [now]);
  }

  @override
  Widget build(BuildContext context) {
    final diasGracia = ref.watch(appSettingsProvider).diasGracia;
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              for (final f in _Filtro.values) ...[
                FilterChip(
                  label: Text(_label(f)),
                  selected: _filtro == f,
                  onSelected: (_) {
                    setState(() => _filtro = f);
                    if (f == _Filtro.mora) _marcarMoraComoVista();
                  },
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        Expanded(
          child: _CuotasList(filtro: _filtro, diasGracia: diasGracia),
        ),
      ],
    );
  }

  String _label(_Filtro f) => switch (f) {
        _Filtro.todas => 'Pendientes',
        _Filtro.mora => 'En mora',
        _Filtro.gracia => 'En gracia',
        _Filtro.parciales => 'Parciales',
        _Filtro.hoy => 'Vencen hoy',
      };
}

class _CuotasList extends StatefulWidget {
  const _CuotasList({required this.filtro, required this.diasGracia});
  final _Filtro filtro;
  final int diasGracia;

  @override
  State<_CuotasList> createState() => _CuotasListState();
}

class _CuotasListState extends State<_CuotasList> {
  // Cacheamos el stream de PowerSync en initState para evitar que cada
  // rebuild cree una nueva suscripción (anti-patrón ps.db.watch inline).
  // El stream se recrea en didUpdateWidget cuando cambian filtro o diasGracia.
  late Stream<List<Map<String, dynamic>>> _cuotasStream;

  @override
  void initState() {
    super.initState();
    _cuotasStream = _buildStream();
  }

  @override
  void didUpdateWidget(_CuotasList old) {
    super.didUpdateWidget(old);
    if (old.filtro != widget.filtro || old.diasGracia != widget.diasGracia) {
      setState(() => _cuotasStream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    final (String extra, List<Object?> params) = switch (widget.filtro) {
      _Filtro.todas => (
          "AND cu.estado IN ('pendiente','parcial')",
          <Object?>[],
        ),
      _Filtro.mora => (
          "AND cu.estado IN ('pendiente','parcial') "
              "AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now')",
          <Object?>[widget.diasGracia],
        ),
      _Filtro.gracia => (
          "AND cu.estado IN ('pendiente','parcial') "
              "AND cu.fecha_vencimiento < date('now') "
              "AND date(cu.fecha_vencimiento, '+' || ? || ' days') >= date('now')",
          <Object?>[widget.diasGracia],
        ),
      _Filtro.parciales => ("AND cu.estado = 'parcial'", <Object?>[]),
      _Filtro.hoy => (
          "AND cu.estado IN ('pendiente','parcial') "
              "AND cu.fecha_vencimiento = date('now')",
          <Object?>[],
        ),
    };

    // Mora: ordenar por comunidad → cliente (ruta del día: minimizar
    // viajes agrupando por zona). Otros filtros: por vencimiento.
    final orderBy = widget.filtro == _Filtro.mora
        ? 'ORDER BY co.nombre, c.nombre'
        : 'ORDER BY cu.fecha_vencimiento ASC, c.nombre';

    final sql = '''
      SELECT cu.id, cu.monto, cu.monto_pagado, cu.fecha_vencimiento,
             cu.periodo, cu.estado,
             c.id AS cliente_id, c.nombre AS cliente_nombre,
             co.nombre AS comunidad
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN comunidades co ON co.id = c.comunidad_id
       WHERE c.activo = 1
         $extra
       $orderBy
    ''';

    return ps.db.watch(sql, parameters: params);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _cuotasStream,
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.check_circle_outline,
            titulo: 'Nada por cobrar',
            descripcion: 'No hay cuotas que coincidan con el filtro.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 80),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
          itemBuilder: (_, i) => _CuotaListTile(row: rows[i], diasGracia: widget.diasGracia),
        );
      },
    );
  }
}

class _CuotaListTile extends StatelessWidget {
  const _CuotaListTile({required this.row, required this.diasGracia});
  final Map<String, dynamic> row;
  final int diasGracia;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vence = DateTime.parse(row['fecha_vencimiento'] as String);
    final saldo = (row['monto'] as num).toDouble() -
        (row['monto_pagado'] as num? ?? 0).toDouble();
    final diasFromVence =
        DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)
            .difference(DateTime(vence.year, vence.month, vence.day))
            .inDays;

    final (label, color, icon) = diasFromVence > diasGracia
        ? ('Vencida hace ${diasFromVence - diasGracia} día(s)', scheme.error,
            Icons.warning)
        : diasFromVence > 0
            ? ('En gracia', scheme.tertiary, Icons.schedule)
            : diasFromVence == 0
                ? ('Vence hoy', scheme.primary, Icons.event)
                : ('Vence en ${-diasFromVence} día(s)', scheme.outline,
                    Icons.event);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.15),
        child: Icon(icon, color: color),
      ),
      title: Text(row['cliente_nombre'] as String,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (row['comunidad'] != null)
            Text(row['comunidad'] as String,
                style: TextStyle(color: scheme.outline, fontSize: 12)),
          Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w500)),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(Fmt.cordobas(saldo),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(Fmt.fechaCorta(vence),
              style: TextStyle(color: scheme.outline, fontSize: 11)),
        ],
      ),
      onTap: () => context.push('/cobro/${row['id']}'),
    );
  }
}
