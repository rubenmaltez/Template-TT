import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';

class ClientesAdminScreen extends ConsumerStatefulWidget {
  const ClientesAdminScreen({super.key});

  @override
  ConsumerState<ClientesAdminScreen> createState() =>
      _ClientesAdminScreenState();
}

class _ClientesAdminScreenState extends ConsumerState<ClientesAdminScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String? _cobradorFilter; // null = todos
  String? _comunidadFilter;
  bool _soloMora = false;
  bool _soloSinCobrador = false;
  final Set<String> _seleccionados = {};
  Timer? _debounce;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = v.trim().toLowerCase());
    });
  }

  @override
  Widget build(BuildContext context) {
    final diasGracia = ref.watch(appSettingsProvider).diasGracia;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearch,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Buscar cliente por nombre, cédula o teléfono',
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                icon: const Icon(Icons.person_add),
                label: const Text('Nuevo cliente'),
                onPressed: () => context.go('/admin/clientes/nuevo'),
              ),
            ],
          ),
        ),
        _Filtros(
          cobradorActual: _cobradorFilter,
          comunidadActual: _comunidadFilter,
          soloMora: _soloMora,
          soloSinCobrador: _soloSinCobrador,
          onCobrador: (v) => setState(() => _cobradorFilter = v),
          onComunidad: (v) => setState(() => _comunidadFilter = v),
          onSoloMora: (v) => setState(() => _soloMora = v),
          onSoloSinCobrador: (v) => setState(() => _soloSinCobrador = v),
        ),
        if (_seleccionados.isNotEmpty)
          _BulkBar(
            cantidad: _seleccionados.length,
            onClear: () => setState(() => _seleccionados.clear()),
            onAssign: () => _bulkAssign(context),
          ),
        Expanded(
          child: _Lista(
            query: _query,
            cobradorFilter: _cobradorFilter,
            comunidadFilter: _comunidadFilter,
            soloMora: _soloMora,
            soloSinCobrador: _soloSinCobrador,
            diasGracia: diasGracia,
            seleccionados: _seleccionados,
            onToggle: (id) => setState(() {
              if (!_seleccionados.add(id)) _seleccionados.remove(id);
            }),
          ),
        ),
      ],
    );
  }

  Future<void> _bulkAssign(BuildContext context) async {
    final seleccion = await showDialog<({String? id, String label})>(
      context: context,
      builder: (_) => const _SeleccionarCobradorDialog(),
    );
    if (seleccion == null || !context.mounted) return;

    final ids = _seleccionados.toList();
    // Confirmar antes de aplicar — bulk-assign no tiene undo.
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar asignación masiva'),
        content: Text(
          'Vas a ${seleccion.id == null ? 'desasignar' : 'asignar a "${seleccion.label}"'} '
          '${ids.length} cliente(s).\n\n'
          'Esta acción se registra en auditoría y no se puede deshacer en lote.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Asignar'),
          ),
        ],
      ),
    );
    if (confirmar != true || !context.mounted) return;

    final now = DateTime.now().toIso8601String();
    await ps.db.writeTransaction((tx) async {
      for (final id in ids) {
        await tx.execute(
          'UPDATE clientes SET cobrador_id = ?, updated_at = ? WHERE id = ?',
          [seleccion.id, now, id],
        );
      }
    });
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${ids.length} cliente(s) actualizados')),
      );
      setState(() => _seleccionados.clear());
    }
  }
}

class _Filtros extends StatelessWidget {
  const _Filtros({
    required this.cobradorActual,
    required this.comunidadActual,
    required this.soloMora,
    required this.soloSinCobrador,
    required this.onCobrador,
    required this.onComunidad,
    required this.onSoloMora,
    required this.onSoloSinCobrador,
  });

  final String? cobradorActual;
  final String? comunidadActual;
  final bool soloMora;
  final bool soloSinCobrador;
  final ValueChanged<String?> onCobrador;
  final ValueChanged<String?> onComunidad;
  final ValueChanged<bool> onSoloMora;
  final ValueChanged<bool> onSoloSinCobrador;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _CobradorChip(seleccionado: cobradorActual, onChanged: onCobrador),
          const SizedBox(width: 8),
          _ComunidadChip(seleccionada: comunidadActual, onChanged: onComunidad),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Sin cobrador'),
            selected: soloSinCobrador,
            onSelected: onSoloSinCobrador,
          ),
          const SizedBox(width: 8),
          FilterChip(
            avatar: const Icon(Icons.warning_amber, size: 18),
            label: const Text('Con mora'),
            selected: soloMora,
            onSelected: onSoloMora,
          ),
        ],
      ),
    );
  }
}

class _CobradorChip extends StatelessWidget {
  const _CobradorChip({required this.seleccionado, required this.onChanged});
  final String? seleccionado;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: ps.db.watch(
        '''
        SELECT id, nombre FROM cobradores
         WHERE activo = 1 AND rol = 'cobrador'
         ORDER BY nombre
        ''',
      ),
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        final label = seleccionado == null
            ? 'Cobrador'
            : (rows.firstWhere((r) => r['id'] == seleccionado,
                    orElse: () => {'nombre': 'Cobrador'})['nombre'] as String);
        return ActionChip(
          avatar: const Icon(Icons.person, size: 18),
          label: Text(label),
          onPressed: () async {
            final picked = await showModalBottomSheet<String?>(
              context: context,
              showDragHandle: true,
              builder: (ctx) => SafeArea(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.clear_all),
                      title: const Text('Todos los cobradores'),
                      onTap: () => Navigator.pop(ctx, null),
                    ),
                    const Divider(height: 1),
                    ...rows.map((r) => ListTile(
                          title: Text(r['nombre'] as String),
                          onTap: () => Navigator.pop(ctx, r['id'] as String),
                        )),
                  ],
                ),
              ),
            );
            onChanged(picked);
          },
        );
      },
    );
  }
}

class _ComunidadChip extends StatelessWidget {
  const _ComunidadChip({required this.seleccionada, required this.onChanged});
  final String? seleccionada;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: ps.db.watch(
        '''
        SELECT co.id, co.nombre, m.nombre AS mun
          FROM comunidades co
          JOIN municipios m ON m.id = co.municipio_id
         ORDER BY m.nombre, co.nombre
        ''',
      ),
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        final label = seleccionada == null
            ? 'Comunidad'
            : (rows.firstWhere((r) => r['id'] == seleccionada,
                    orElse: () => {'nombre': 'Comunidad'})['nombre'] as String);
        return ActionChip(
          avatar: const Icon(Icons.place, size: 18),
          label: Text(label),
          onPressed: () async {
            final picked = await showModalBottomSheet<String?>(
              context: context,
              showDragHandle: true,
              builder: (ctx) => SafeArea(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.clear_all),
                      title: const Text('Todas'),
                      onTap: () => Navigator.pop(ctx, null),
                    ),
                    const Divider(height: 1),
                    ...rows.map((r) => ListTile(
                          title: Text(r['nombre'] as String),
                          subtitle: Text(r['mun'] as String),
                          onTap: () => Navigator.pop(ctx, r['id'] as String),
                        )),
                  ],
                ),
              ),
            );
            onChanged(picked);
          },
        );
      },
    );
  }
}

class _BulkBar extends StatelessWidget {
  const _BulkBar({
    required this.cantidad,
    required this.onClear,
    required this.onAssign,
  });
  final int cantidad;
  final VoidCallback onClear;
  final VoidCallback onAssign;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: onClear,
            ),
            Text('$cantidad seleccionado(s)'),
            const Spacer(),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Asignar cobrador'),
              onPressed: onAssign,
            ),
          ],
        ),
      ),
    );
  }
}

class _Lista extends StatelessWidget {
  const _Lista({
    required this.query,
    required this.cobradorFilter,
    required this.comunidadFilter,
    required this.soloMora,
    required this.soloSinCobrador,
    required this.diasGracia,
    required this.seleccionados,
    required this.onToggle,
  });

  final String query;
  final String? cobradorFilter;
  final String? comunidadFilter;
  final bool soloMora;
  final bool soloSinCobrador;
  final int diasGracia;
  final Set<String> seleccionados;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final where = <String>['c.activo = 1'];
    final params = <Object?>[diasGracia];

    if (query.isNotEmpty) {
      where.add(
          '(lower(c.nombre) LIKE ? OR lower(coalesce(c.cedula,\'\')) LIKE ? OR coalesce(c.telefono,\'\') LIKE ?)');
      final like = '%$query%';
      params..add(like)..add(like)..add(like);
    }
    if (cobradorFilter != null) {
      where.add('c.cobrador_id = ?');
      params.add(cobradorFilter);
    }
    if (comunidadFilter != null) {
      where.add('c.comunidad_id = ?');
      params.add(comunidadFilter);
    }
    if (soloSinCobrador) {
      where.add('c.cobrador_id IS NULL');
    }

    final having = soloMora ? 'HAVING vencidas > 0' : '';

    final sql = '''
      SELECT c.id, c.nombre, c.telefono, c.direccion_referencia,
             c.cobrador_id,
             co.nombre AS cobrador_nombre,
             cm.nombre AS comunidad, m.nombre AS municipio,
             COUNT(cu.id) FILTER (
               WHERE cu.estado IN ('pendiente','parcial')
                 AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now')
             ) AS vencidas,
             COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                                THEN cu.monto - cu.monto_pagado ELSE 0 END), 0) AS saldo
        FROM clientes c
   LEFT JOIN cobradores  co ON co.id = c.cobrador_id
   LEFT JOIN comunidades cm ON cm.id = c.comunidad_id
   LEFT JOIN municipios  m  ON m.id = cm.municipio_id
   LEFT JOIN cuotas      cu ON cu.cliente_id = c.id
       WHERE ${where.join(' AND ')}
       GROUP BY c.id, c.nombre, c.telefono, c.direccion_referencia,
                c.cobrador_id, co.nombre, cm.nombre, m.nombre
       $having
       ORDER BY c.nombre
    ''';

    return StreamBuilder(
      stream: ps.db.watch(sql, parameters: params),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.people_outline,
            titulo: 'Sin clientes',
            descripcion: 'Ajustá filtros o creá uno nuevo.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final r = rows[i];
            final selected = seleccionados.contains(r['id']);
            return _ClienteCard(
              row: r,
              selected: selected,
              onToggle: () => onToggle(r['id'] as String),
            );
          },
        );
      },
    );
  }
}

class _ClienteCard extends StatelessWidget {
  const _ClienteCard({
    required this.row,
    required this.selected,
    required this.onToggle,
  });

  final Map<String, dynamic> row;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vencidas = row['vencidas'] as int? ?? 0;
    final saldo = (row['saldo'] as num? ?? 0).toDouble();
    final sinCobrador = row['cobrador_id'] == null;

    return Card(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
      child: InkWell(
        onTap: () => context.go('/admin/clientes/${row['id']}/editar'),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: (_) => onToggle(),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row['nombre'] as String,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (row['comunidad'] != null)
                      Text('${row['comunidad']} · ${row['municipio'] ?? ''}',
                          style: TextStyle(color: scheme.outline, fontSize: 12)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: [
                        if (sinCobrador)
                          Chip(
                            avatar: Icon(Icons.person_off, size: 14, color: scheme.error),
                            label: const Text('Sin cobrador'),
                            backgroundColor: scheme.errorContainer.withValues(alpha: 0.3),
                            visualDensity: VisualDensity.compact,
                          )
                        else
                          Chip(
                            avatar: const Icon(Icons.person, size: 14),
                            label: Text(row['cobrador_nombre'] as String? ?? '—'),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (vencidas > 0)
                          Chip(
                            avatar: Icon(Icons.warning, size: 14, color: scheme.error),
                            label: Text('$vencidas vencida(s)'),
                            backgroundColor: scheme.errorContainer.withValues(alpha: 0.3),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    Fmt.cordobas(saldo),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: vencidas > 0 ? scheme.error : null,
                    ),
                  ),
                  Text('Saldo',
                      style: TextStyle(color: scheme.outline, fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeleccionarCobradorDialog extends StatelessWidget {
  const _SeleccionarCobradorDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Asignar cobrador'),
      content: SizedBox(
        width: 400,
        child: StreamBuilder(
          stream: ps.db.watch(
            '''
            SELECT id, nombre, prefijo_recibo FROM cobradores
             WHERE activo = 1 AND rol = 'cobrador'
             ORDER BY nombre
            ''',
          ),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const SizedBox(
                  height: 100, child: Center(child: CircularProgressIndicator()));
            }
            final rows = snap.data!;
            return ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: const Icon(Icons.person_off),
                  title: const Text('Desasignar (sin cobrador)'),
                  onTap: () => Navigator.pop(
                      context, (id: null, label: 'Sin cobrador')),
                ),
                const Divider(height: 1),
                ...rows.map((r) => ListTile(
                      leading: const Icon(Icons.person),
                      title: Text(r['nombre'] as String),
                      subtitle: Text(r['prefijo_recibo'] as String? ?? '—'),
                      onTap: () => Navigator.pop(
                          context,
                          (
                            id: r['id'] as String,
                            label: r['nombre'] as String
                          )),
                    )),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

