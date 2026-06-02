import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';

/// Bandeja de notificaciones de mora. Las genera el cron diario; aquí se
/// marcan como vistas y/o se navega al cliente para gestionarlas.
class NotificacionesMoraScreen extends ConsumerStatefulWidget {
  const NotificacionesMoraScreen({super.key});

  @override
  ConsumerState<NotificacionesMoraScreen> createState() =>
      _NotificacionesMoraScreenState();
}

class _NotificacionesMoraScreenState
    extends ConsumerState<NotificacionesMoraScreen> {
  bool _soloPendientes = true;
  late Stream<List<Map<String, dynamic>>> _notificacionesStream;

  @override
  void initState() {
    super.initState();
    _buildStream();
  }

  void _buildStream() {
    _notificacionesStream = ps.db.watch(
      '''
      SELECT n.id, n.cuota_id, n.cliente_id, n.cobrador_id,
             n.dias_mora, n.monto_adeudado, n.generada_en,
             n.vista_en, n.resuelta_en,
             c.nombre AS cliente_nombre, c.telefono,
             co.nombre AS cobrador_nombre,
             cu.fecha_vencimiento, cu.estado AS cuota_estado
        FROM notificaciones_mora n
        JOIN clientes c ON c.id = n.cliente_id
        JOIN cuotas cu ON cu.id = n.cuota_id
   LEFT JOIN cobradores co ON co.id = n.cobrador_id
       ${_soloPendientes ? 'WHERE n.resuelta_en IS NULL' : ''}
       ORDER BY n.dias_mora DESC, n.generada_en DESC
       LIMIT 200
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    // Pantalla opcional gateada por super_admin (cobranza.pantalla_notificaciones).
    // Si está OFF el menú no la muestra; este guard bloquea el acceso por URL
    // directa (defensa en profundidad — la RLS 0085 ya impide que el admin la
    // active). El super_admin la habilita desde el panel de settings.
    if (!ref.watch(appSettingsProvider).pantallaNotificacionesHabilitada) {
      return const EmptyState(
        icon: Icons.lock_outline,
        titulo: 'Sección no habilitada',
        descripcion: 'Esta sección no está habilitada para tu empresa. '
            'El administrador del sistema puede activarla.',
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              FilterChip(
                label: const Text('Sólo no resueltas'),
                selected: _soloPendientes,
                onSelected: (v) => setState(() {
                  _soloPendientes = v;
                  _buildStream();
                }),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _notificacionesStream,
            initialData: const [],
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text('Error: ${snap.error}'));
              }
              final rows = snap.data!;
              if (rows.isEmpty) {
                return EmptyState(
                  icon: Icons.check_circle_outline,
                  titulo: 'Sin notificaciones',
                  descripcion: _soloPendientes
                      ? 'Todas las moras están resueltas.'
                      : 'El cron genera notificaciones cuando una cuota '
                          'pasa los días de gracia.',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, i) => _NotificacionCard(row: rows[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NotificacionCard extends ConsumerWidget {
  const _NotificacionCard({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final dias = row['dias_mora'] as int;
    final resuelta = row['resuelta_en'] != null;
    final vista = row['vista_en'] != null;

    return Card(
      color: resuelta ? scheme.surfaceContainerLow : null,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: resuelta
              ? scheme.tertiaryContainer
              : scheme.errorContainer,
          child: Icon(
            resuelta ? Icons.check : Icons.warning,
            color: resuelta ? scheme.tertiary : scheme.error,
          ),
        ),
        title: Text(row['cliente_nombre'] as String),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$dias día(s) de mora · ${Fmt.cordobas(row['monto_adeudado'] as num)}',
              style: TextStyle(
                color: resuelta ? scheme.outline : scheme.error,
              ),
            ),
            if (row['cobrador_nombre'] != null)
              Text('Cobrador: ${row['cobrador_nombre']}',
                  style: TextStyle(color: scheme.outline, fontSize: 11)),
            if (resuelta)
              Text('Resuelta',
                  style: TextStyle(color: scheme.tertiary, fontSize: 11)),
            if (vista && !resuelta)
              Text('Vista',
                  style: TextStyle(color: scheme.outline, fontSize: 11)),
          ],
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (action) => _accion(context, ref, action),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'cliente', child: Text('Ver cliente')),
            if (row['telefono'] != null)
              const PopupMenuItem(value: 'tel', child: Text('Copiar teléfono')),
            if (!vista && !resuelta)
              const PopupMenuItem(value: 'vista', child: Text('Marcar como vista')),
          ],
        ),
        onTap: () => context.push('/clientes/${row['cliente_id']}'),
      ),
    );
  }

  Future<void> _accion(BuildContext context, WidgetRef ref, String action) async {
    switch (action) {
      case 'cliente':
        context.push('/clientes/${row['cliente_id']}');
        break;
      case 'tel':
        final tel = row['telefono'] as String?;
        if (tel != null) {
          await Clipboard.setData(ClipboardData(text: tel));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Teléfono $tel copiado')),
            );
          }
        }
        break;
      case 'vista':
        final me = ref.read(cobradorActualProvider).valueOrNull;
        if (me == null) return;
        await ps.db.execute(
          'UPDATE notificaciones_mora SET vista_en = ?, vista_por = ? WHERE id = ?',
          [DateTime.now().toIso8601String(), me.id, row['id']],
        );
        break;
    }
  }
}
