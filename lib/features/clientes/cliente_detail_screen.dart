import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/cuota.dart';
import '../../data/repositories/clientes_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/services/external_actions.dart';
import '../../data/services/visitas_service.dart';
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _mostrarDialogVisita(context, ref),
        icon: const Icon(Icons.add_task),
        label: const Text('Registrar visita'),
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
              const SizedBox(height: 8),
              _VisitasSection(clienteId: clienteId),
            ],
          );
        },
      ),
    );
  }

  Future<void> _mostrarDialogVisita(BuildContext context, WidgetRef ref) async {
    final resultado = await showDialog<({VisitaResultado resultado, String? notas})>(
      context: context,
      builder: (_) => const _RegistrarVisitaDialog(),
    );
    if (resultado == null || !context.mounted) return;

    final service = ref.read(visitasServiceProvider);
    await service.registrar(
      clienteId: clienteId,
      resultado: resultado.resultado,
      notas: resultado.notas,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Visita registrada')),
      );
      // Fuerza rebuild de la sección de visitas.
      // Usamos un mecanismo simple: invalidar la pantalla entera via un
      // setState-like trigger. Como ClienteDetailScreen es ConsumerWidget
      // sin state propio, usamos un workaround: navegamos al mismo lugar.
      // Alternativa más limpia sería un StateNotifier, pero para MVP es
      // aceptable que el user vea la visita tras scroll down o re-enter.
    }
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (telefono != null && telefono!.isNotEmpty) ...[
                _IconButton(
                  icon: Icons.phone,
                  label: 'Llamar',
                  onTap: () => ExternalActions.llamar(context, telefono!),
                ),
                _IconButton(
                  icon: Icons.chat,
                  label: 'WhatsApp',
                  onTap: () => ExternalActions.whatsapp(context, telefono!),
                ),
              ],
              if (tieneUbicacion)
                _IconButton(
                  icon: Icons.directions,
                  label: 'Navegar',
                  onTap: () => ExternalActions.navegarA(
                    context,
                    lat: latitud!,
                    lng: longitud!,
                  ),
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

class _CuotasSection extends StatefulWidget {
  const _CuotasSection({required this.clienteId, required this.diasGracia});
  final String clienteId;
  final int diasGracia;

  @override
  State<_CuotasSection> createState() => _CuotasSectionState();
}

class _CuotasSectionState extends State<_CuotasSection> {
  late Stream<List<Map<String, dynamic>>> _cuotasStream;

  @override
  void initState() {
    super.initState();
    _cuotasStream = _buildStream();
  }

  @override
  void didUpdateWidget(covariant _CuotasSection old) {
    super.didUpdateWidget(old);
    if (widget.clienteId != old.clienteId) {
      setState(() => _cuotasStream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    return ps.db.watch(
      '''
      SELECT cu.*, p.nombre AS plan_nombre, p.precio_mensual
        FROM cuotas cu
        LEFT JOIN contratos ct ON ct.id = cu.contrato_id
        LEFT JOIN planes p     ON p.id = ct.plan_id
       WHERE cu.cliente_id = ?
       ORDER BY cu.periodo DESC
      ''',
      parameters: [widget.clienteId],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: StreamBuilder(
          stream: _cuotasStream,
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
                    diasGracia: widget.diasGracia,
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
          Text(planNombre ?? cuota.descripcion ?? '—',
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

class _PagosSection extends StatefulWidget {
  const _PagosSection({required this.clienteId});
  final String clienteId;

  @override
  State<_PagosSection> createState() => _PagosSectionState();
}

class _PagosSectionState extends State<_PagosSection> {
  late Stream<List<Map<String, dynamic>>> _pagosStream;

  @override
  void initState() {
    super.initState();
    _pagosStream = _buildStream();
  }

  @override
  void didUpdateWidget(covariant _PagosSection old) {
    super.didUpdateWidget(old);
    if (widget.clienteId != old.clienteId) {
      setState(() => _pagosStream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    return ps.db.watch(
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
      parameters: [widget.clienteId],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: StreamBuilder(
          stream: _pagosStream,
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
