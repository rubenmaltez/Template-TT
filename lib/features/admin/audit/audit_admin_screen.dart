import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';

class AuditAdminScreen extends StatefulWidget {
  const AuditAdminScreen({super.key});
  @override
  State<AuditAdminScreen> createState() => _AuditAdminScreenState();
}

class _AuditAdminScreenState extends State<AuditAdminScreen> {
  String? _filtroTabla; // null = todas

  static const _tablas = [
    'settings',
    'clientes',
    'pagos',
    'recibos',
    'cuotas',
  ];

  @override
  Widget build(BuildContext context) {
    final where = _filtroTabla == null ? '' : "WHERE tabla = ?";
    final params = _filtroTabla == null ? <Object?>[] : <Object?>[_filtroTabla];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Todas'),
                  selected: _filtroTabla == null,
                  onSelected: (_) => setState(() => _filtroTabla = null),
                ),
                const SizedBox(width: 8),
                for (final t in _tablas) ...[
                  ChoiceChip(
                    label: Text(t),
                    selected: _filtroTabla == t,
                    onSelected: (_) => setState(() => _filtroTabla = t),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder(
            stream: ps.db.watch(
              '''
              SELECT a.id, a.tabla, a.registro_id, a.campo,
                     a.valor_anterior, a.valor_nuevo,
                     a.user_id, a.user_rol, a.created_at,
                     co.nombre AS user_nombre
                FROM audit_log a
           LEFT JOIN cobradores co ON co.id = a.user_id
               $where
               ORDER BY a.created_at DESC
               LIMIT 200
              ''',
              parameters: params,
            ),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snap.data!;
              if (rows.isEmpty) {
                return const EmptyState(
                  icon: Icons.history_edu,
                  titulo: 'Sin registros de auditoría',
                  descripcion: 'Los cambios sensibles aparecen acá '
                      '(settings, asignaciones, anulaciones).',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _AuditTile(row: rows[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AuditTile extends StatelessWidget {
  const _AuditTile({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cuando = DateTime.parse(row['created_at'] as String);
    final tabla = row['tabla'] as String;
    final campo = row['campo'] as String?;
    final usuario = row['user_nombre'] as String? ?? 'Sistema';
    final rol = row['user_rol'] as String? ?? '';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: _color(tabla, scheme).withValues(alpha: 0.15),
        child: Icon(_icon(tabla), color: _color(tabla, scheme), size: 18),
      ),
      title: Text('$tabla${campo != null ? ' · $campo' : ''}',
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$usuario ($rol) · ${Fmt.fechaCorta(cuando)} ${Fmt.hora(cuando)}',
              style: TextStyle(color: scheme.outline, fontSize: 12)),
          if (row['valor_anterior'] != null || row['valor_nuevo'] != null) ...[
            const SizedBox(height: 4),
            _DiffText(
              anterior: row['valor_anterior'] as String?,
              nuevo: row['valor_nuevo'] as String?,
            ),
          ],
        ],
      ),
    );
  }

  IconData _icon(String tabla) => switch (tabla) {
        'settings' => Icons.settings,
        'clientes' => Icons.person,
        'pagos' => Icons.payments,
        'recibos' => Icons.receipt,
        'cuotas' => Icons.assignment,
        _ => Icons.history,
      };

  Color _color(String tabla, ColorScheme s) => switch (tabla) {
        'settings' => s.primary,
        'pagos' => s.error,
        'recibos' => s.error,
        'cuotas' => s.error,
        _ => s.secondary,
      };
}

class _DiffText extends StatelessWidget {
  const _DiffText({required this.anterior, required this.nuevo});
  final String? anterior;
  final String? nuevo;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (anterior != null) ...[
          Text(_pretty(anterior!),
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
                decoration: TextDecoration.lineThrough,
              )),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.arrow_forward, size: 12),
          ),
        ],
        if (nuevo != null)
          Text(_pretty(nuevo!),
              style: TextStyle(
                color: Theme.of(context).colorScheme.tertiary,
                fontSize: 12,
              )),
      ],
    );
  }

  String _pretty(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.toString();
      return decoded.toString();
    } catch (_) {
      return raw;
    }
  }
}
