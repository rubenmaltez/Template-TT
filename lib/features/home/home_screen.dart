import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../powersync/db.dart' as ps;
import '../../data/utils/formatters.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final settings = ref.watch(appSettingsProvider);
    final now = DateTime.now();
    final hoyStr = DateTime(now.year, now.month, now.day).toIso8601String().substring(0, 10);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Saludo ────────────────────────────────────────────────────
        Text('Hola, ${cobrador?.nombre.split(" ").first ?? "—"} 👋',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('${Fmt.diaSemana(now)}, ${Fmt.fechaLarga(now)}',
            style: TextStyle(color: Theme.of(context).colorScheme.outline)),

        const SizedBox(height: 24),

        // ── Métricas del día ──────────────────────────────────────────
        _DashboardMetrics(diasGracia: settings.diasGracia, hoyIso: hoyStr),

        const SizedBox(height: 24),

        // ── Accesos rápidos ───────────────────────────────────────────
        Text('Accesos rápidos', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.6,
          physics: const NeverScrollableScrollPhysics(),
          children: const [
            _QuickAction(icon: Icons.people, label: 'Clientes', path: '/clientes'),
            _QuickAction(icon: Icons.receipt_long, label: 'Cuotas', path: '/cuotas'),
            _QuickAction(icon: Icons.map, label: 'Mapa', path: '/mapa'),
            _QuickAction(icon: Icons.history, label: 'Historial', path: '/historial'),
          ],
        ),
      ],
    );
  }
}

class _DashboardMetrics extends StatelessWidget {
  const _DashboardMetrics({required this.diasGracia, required this.hoyIso});
  final int diasGracia;
  final String hoyIso;

  @override
  Widget build(BuildContext context) {
    // Una sola query para todas las métricas. Se re-emite ante cualquier
    // cambio en cuotas o pagos.
    return StreamBuilder(
      stream: ps.db.watch(
        '''
        SELECT
          (SELECT COUNT(*) FROM clientes WHERE activo = 1) AS clientes_total,

          (SELECT COUNT(*) FROM cuotas
             WHERE estado IN ('pendiente','parcial')) AS cuotas_pendientes,

          (SELECT COALESCE(SUM(monto - monto_pagado), 0) FROM cuotas
             WHERE estado IN ('pendiente','parcial')) AS saldo_total,

          (SELECT COUNT(*) FROM cuotas
             WHERE estado IN ('pendiente','parcial')
               AND date(fecha_vencimiento, '+' || ? || ' days') < date('now')
          ) AS cuotas_vencidas,

          (SELECT COUNT(*) FROM pagos
             WHERE date(fecha_pago) = ?) AS pagos_hoy,

          (SELECT COALESCE(SUM(monto_cordobas), 0) FROM pagos
             WHERE date(fecha_pago) = ?) AS cobrado_hoy
        ''',
        parameters: [diasGracia, hoyIso, hoyIso],
      ),
      builder: (context, snap) {
        if (!snap.hasData || snap.data!.isEmpty) {
          return const _MetricsSkeleton();
        }
        final r = snap.data!.first;
        return Column(
          children: [
            _MetricCard(
              icon: Icons.attach_money,
              titulo: 'Cobrado hoy',
              valor: Fmt.cordobas(r['cobrado_hoy'] as num),
              sub: '${r['pagos_hoy']} cobro(s)',
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _MetricCard(
                    icon: Icons.pending_actions,
                    titulo: 'Por cobrar',
                    valor: '${r['cuotas_pendientes']}',
                    sub: Fmt.cordobas(r['saldo_total'] as num),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MetricCard(
                    icon: Icons.warning_amber,
                    titulo: 'En mora',
                    valor: '${r['cuotas_vencidas']}',
                    sub: 'Más de $diasGracia días',
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _MetricCard(
              icon: Icons.people,
              titulo: 'Clientes asignados',
              valor: '${r['clientes_total']}',
              sub: 'Activos en tu ruta',
            ),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.titulo,
    required this.valor,
    this.sub,
    this.color,
  });

  final IconData icon;
  final String titulo;
  final String valor;
  final String? sub;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: c, size: 20),
                const SizedBox(width: 8),
                Text(titulo,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 8),
            Text(valor, style: Theme.of(context).textTheme.headlineSmall),
            if (sub != null) ...[
              const SizedBox(height: 2),
              Text(sub!,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetricsSkeleton extends StatelessWidget {
  const _MetricsSkeleton();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(40),
        child: CircularProgressIndicator(),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.path});
  final IconData icon;
  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.go(path),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              Text(label, style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
        ),
      ),
    );
  }
}
