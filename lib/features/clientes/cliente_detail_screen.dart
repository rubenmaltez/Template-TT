import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/cuota.dart';
import '../../data/repositories/clientes_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';

class ClienteDetailScreen extends ConsumerWidget {
  const ClienteDetailScreen({super.key, required this.clienteId});
  final String clienteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clienteAsync = ref.watch(clienteByIdProvider(clienteId));
    final diasGracia = ref.watch(appSettingsProvider).diasGracia;

    return Scaffold(
      appBar: AppBar(
        title: clienteAsync.when(
          data: (c) => Text(c?.nombre ?? 'Cliente'),
          loading: () => const Text('Cliente'),
          error: (_, __) => const Text('Cliente'),
        ),
      ),
      body: clienteAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (cliente) {
          if (cliente == null) {
            return const EmptyState(
              icon: Icons.person_off,
              titulo: 'Cliente no encontrado',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              _ClienteHeader(
                nombre: cliente.nombre,
                telefono: cliente.telefono,
                tieneUbicacion: cliente.tieneUbicacion,
                latitud: cliente.latitud,
                longitud: cliente.longitud,
              ),
              _ClienteInfo(cliente: cliente),
              const SizedBox(height: 8),
              _CuotasSection(clienteId: clienteId, diasGracia: diasGracia),
              const SizedBox(height: 8),
              _PagosSection(clienteId: clienteId),
            ],
          );
        },
      ),
    );
  }
}

class _ClienteHeader extends StatelessWidget {
  const _ClienteHeader({
    required this.nombre,
    required this.telefono,
    required this.tieneUbicacion,
    required this.latitud,
    required this.longitud,
  });
  final String nombre;
  final String? telefono;
  final bool tieneUbicacion;
  final double? latitud;
  final double? longitud;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.primaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(nombre, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          Row(
            children: [
              if (telefono != null && telefono!.isNotEmpty)
                _IconButton(
                  icon: Icons.phone,
                  label: 'Llamar',
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: telefono!));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Teléfono $telefono copiado')),
                      );
                    }
                  },
                ),
              const SizedBox(width: 8),
              if (tieneUbicacion)
                _IconButton(
                  icon: Icons.map,
                  label: 'Ver en mapa',
                  onTap: () => Navigator.of(context).pop(),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: Icon(icon),
      label: Text(label),
      onPressed: onTap,
    );
  }
}

class _ClienteInfo extends StatelessWidget {
  const _ClienteInfo({required this.cliente});
  final dynamic cliente;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(context, Icons.badge, 'Cédula', cliente.cedula),
              _row(context, Icons.phone, 'Teléfono', cliente.telefono),
              _row(context, Icons.home, 'Dirección', cliente.direccion),
              _row(context, Icons.location_on, 'Referencia',
                  cliente.direccionReferencia),
              if (cliente.tieneUbicacion)
                _row(context, Icons.gps_fixed, 'GPS',
                    '${cliente.latitud!.toStringAsFixed(5)}, ${cliente.longitud!.toStringAsFixed(5)}'),
            ],
          ),
        ),
      ),
    );
  }

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
          SizedBox(width: 90, child: Text(label, style: TextStyle(color: scheme.outline))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _CuotasSection extends StatelessWidget {
  const _CuotasSection({required this.clienteId, required this.diasGracia});
  final String clienteId;
  final int diasGracia;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: StreamBuilder(
          stream: ps.db.watch(
            '''
            SELECT cu.*, p.nombre AS plan_nombre, p.precio_mensual
              FROM cuotas cu
              LEFT JOIN contratos ct ON ct.id = cu.contrato_id
              LEFT JOIN planes p     ON p.id = ct.plan_id
             WHERE cu.cliente_id = ?
             ORDER BY cu.periodo DESC
            ''',
            parameters: [clienteId],
          ),
          builder: (context, snap) {
            final rows = snap.data ?? const [];
            if (rows.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No hay cuotas todavía',
                    textAlign: TextAlign.center),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text('Cuotas',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                ...rows.map((r) {
                  final cuota = Cuota.fromRow(r);
                  return _CuotaTile(
                    cuota: cuota,
                    planNombre: r['plan_nombre'] as String?,
                    diasGracia: diasGracia,
                  );
                }),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CuotaTile extends StatelessWidget {
  const _CuotaTile({
    required this.cuota,
    required this.planNombre,
    required this.diasGracia,
  });

  final Cuota cuota;
  final String? planNombre;
  final int diasGracia;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final estadoVisual = cuota.estadoVisual(diasGracia);
    final color = switch (estadoVisual) {
      CuotaEstadoVisual.pagada => scheme.tertiary,
      CuotaEstadoVisual.parcial => scheme.secondary,
      CuotaEstadoVisual.enGracia => scheme.tertiary,
      CuotaEstadoVisual.vencida => scheme.error,
      CuotaEstadoVisual.anulada => scheme.outline,
      _ => scheme.primary,
    };

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.15),
        child: Icon(
          estadoVisual == CuotaEstadoVisual.pagada
              ? Icons.check
              : estadoVisual == CuotaEstadoVisual.vencida
                  ? Icons.warning
                  : Icons.receipt_long,
          color: color,
        ),
      ),
      title: Text('${Fmt.mes(cuota.periodo)[0].toUpperCase()}${Fmt.mes(cuota.periodo).substring(1)}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(planNombre ?? '—',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('Vence ${Fmt.fechaCorta(cuota.fechaVencimiento)} · ${estadoVisual.label}',
              style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(Fmt.cordobas(cuota.monto),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (cuota.saldo < cuota.monto && cuota.saldo > 0)
            Text('Saldo: ${Fmt.cordobas(cuota.saldo)}',
                style: TextStyle(color: scheme.outline, fontSize: 11)),
        ],
      ),
      onTap: estadoVisual.esCobrable
          ? () => context.push('/cobro/${cuota.id}')
          : null,
    );
  }
}

class _PagosSection extends StatelessWidget {
  const _PagosSection({required this.clienteId});
  final String clienteId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: StreamBuilder(
          stream: ps.db.watch(
            '''
            SELECT p.id, p.monto_cordobas, p.moneda, p.monto_original,
                   p.metodo, p.fecha_pago, p.referencia,
                   cu.periodo
              FROM pagos p
              JOIN cuotas cu ON cu.id = p.cuota_id
             WHERE cu.cliente_id = ?
             ORDER BY p.fecha_pago DESC
             LIMIT 10
            ''',
            parameters: [clienteId],
          ),
          builder: (context, snap) {
            final rows = snap.data ?? const [];
            if (rows.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text('Últimos pagos',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                ...rows.map((r) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.payments_outlined),
                      title: Text(Fmt.cordobas(r['monto_cordobas'] as num)),
                      subtitle: Text(
                        '${r['metodo']} · ${Fmt.fechaCorta(DateTime.parse(r['fecha_pago'] as String))}',
                      ),
                      trailing: (r['moneda'] as String) == 'USD'
                          ? Text('US\$${(r['monto_original'] as num).toStringAsFixed(2)}',
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.outline))
                          : null,
                    )),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }
}
