import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/validators.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/cargar_mas_button.dart';
import '../../shared/widgets/empty_state.dart';

class ClientesAdminScreen extends ConsumerStatefulWidget {
  const ClientesAdminScreen({super.key});

  @override
  ConsumerState<ClientesAdminScreen> createState() =>
      _ClientesAdminScreenState();
}

/// Página inicial de la lista cuando NO hay búsqueda activa. Sube
/// en increments del mismo tamaño al tocar "Cargar más". Suficiente
/// para navegar el catálogo del tenant sin colgar la UI.
const int _kPageSize = 50;

/// Página inicial cuando HAY búsqueda activa. El WHERE LIKE ya reduce
/// el set drásticamente (10k → decenas en búsquedas típicas), así que
/// queremos retornar todos los matches realistas sin obligar al admin
/// a paginar dentro de su búsqueda. 200 cubre casi todos los casos
/// reales — solo búsquedas muy genéricas ("a") superan ese umbral.
const int _kSearchPageSize = 200;

class _ClientesAdminScreenState extends ConsumerState<ClientesAdminScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String? _cobradorFilter; // null = todos
  String? _comunidadFilter;
  bool _soloMora = false;
  bool _soloSinCobrador = false;
  _FiltroEstado _filtroEstado = _FiltroEstado.activos;
  final Set<String> _seleccionados = {};
  Timer? _debounce;
  // Tamaño actual de la página. Se resetea según haya búsqueda o no
  // (50 sin search, 200 con search) cuando cambia query/filtros, y
  // sube por incrementos del mismo tamaño al tocar "Cargar más".
  int _pageSize = _kPageSize;
  // True desde el tap "Cargar más" hasta que pase un debounce corto.
  // Sirve solo de anti-doble-tap: el SQLite local emite el nuevo
  // snapshot en pocos ms, así que un debounce de 400ms cubre el
  // visual feedback del botón sin atarse al ciclo del stream.
  bool _loadingMore = false;
  Timer? _loadingMoreTimer;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    _loadingMoreTimer?.cancel();
    super.dispose();
  }

  // Tamaño base según haya búsqueda o no. Se usa para el reset y
  // para el incremento de "Cargar más" — así con search activo el
  // primer pintado y cada tap traen 200 (no 50), evitando que el
  // admin tape el botón muchas veces para llegar a su cliente.
  int get _baseSize => _query.isEmpty ? _kPageSize : _kSearchPageSize;

  void _onLoadMore() {
    setState(() {
      _pageSize += _baseSize;
      _loadingMore = true;
    });
    _loadingMoreTimer?.cancel();
    _loadingMoreTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _loadingMore = false);
    });
  }

  void _resetPagination() {
    _pageSize = _baseSize;
    // Limpiar selección al cambiar filtros: sino los IDs quedan en
    // memoria pero invisibles (no entran en el nuevo subset). Riesgo:
    // user selecciona 10, cambia filtro, queda con "10 seleccionado(s)"
    // pero ve 0 de ellos. Bulk-assign actuaría sobre IDs fantasma.
    _seleccionados.clear();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        setState(() {
          _query = v.trim().toLowerCase();
          _resetPagination();
        });
      }
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
                    hintText: 'Buscar por nombre, código, cédula o teléfono',
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() {
                                _query = '';
                                _resetPagination();
                              });
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                icon: const Icon(Icons.person_add),
                label: const Text('Nuevo cliente'),
                onPressed: () => context.push('/admin/clientes/nuevo'),
              ),
            ],
          ),
        ),
        _Filtros(
          cobradorActual: _cobradorFilter,
          comunidadActual: _comunidadFilter,
          soloMora: _soloMora,
          soloSinCobrador: _soloSinCobrador,
          onCobrador: (v) => setState(() {
            _cobradorFilter = v;
            _resetPagination();
          }),
          onComunidad: (v) => setState(() {
            _comunidadFilter = v;
            _resetPagination();
          }),
          onSoloMora: (v) => setState(() {
            _soloMora = v;
            _resetPagination();
          }),
          onSoloSinCobrador: (v) => setState(() {
            _soloSinCobrador = v;
            _resetPagination();
          }),
          filtroEstado: _filtroEstado,
          onFiltroEstado: (v) => setState(() {
            _filtroEstado = v;
            _resetPagination();
          }),
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
            filtroEstado: _filtroEstado,
            diasGracia: diasGracia,
            pageSize: _pageSize,
            seleccionados: _seleccionados,
            onToggle: (id) => setState(() {
              if (!_seleccionados.add(id)) _seleccionados.remove(id);
            }),
            loadingMore: _loadingMore,
            onLoadMore: _onLoadMore,
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
    // Hora REAL del dispositivo (UTC) para el change log — offline-first.
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    await ps.db.writeTransaction((tx) async {
      for (final id in ids) {
        await tx.execute(
          'UPDATE clientes SET cobrador_id = ?, updated_at = ?, ocurrido_en = ? WHERE id = ?',
          [seleccion.id, now, ocurridoEn, id],
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
    required this.filtroEstado,
    required this.onFiltroEstado,
  });

  final String? cobradorActual;
  final String? comunidadActual;
  final bool soloMora;
  final bool soloSinCobrador;
  final _FiltroEstado filtroEstado;
  final ValueChanged<String?> onCobrador;
  final ValueChanged<String?> onComunidad;
  final ValueChanged<bool> onSoloMora;
  final ValueChanged<bool> onSoloSinCobrador;
  final ValueChanged<_FiltroEstado> onFiltroEstado;

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
          const SizedBox(width: 8),
          _EstadoFilterChip(
            value: filtroEstado,
            onChanged: onFiltroEstado,
          ),
        ],
      ),
    );
  }
}

class _CobradorChip extends StatefulWidget {
  const _CobradorChip({required this.seleccionado, required this.onChanged});
  final String? seleccionado;
  final ValueChanged<String?> onChanged;

  @override
  State<_CobradorChip> createState() => _CobradorChipState();
}

class _CobradorChipState extends State<_CobradorChip> {
  /// Stream cacheado — query fija, no depende de props.
  late final Stream<List<Map<String, dynamic>>> _cobradoresStream;

  @override
  void initState() {
    super.initState();
    _cobradoresStream = ps.db.watch(
      '''
      SELECT id, nombre FROM cobradores
       WHERE activo = 1 AND rol = 'cobrador'
       ORDER BY nombre
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cobradoresStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Chip(label: Text('Error: ${snap.error}'));
        }
        final rows = snap.data!;
        String label = 'Cobrador';
        if (widget.seleccionado != null) {
          final sel = rows.where((r) => r['id'] == widget.seleccionado);
          if (sel.isNotEmpty) label = sel.first['nombre'] as String;
        }
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
            widget.onChanged(picked);
          },
        );
      },
    );
  }
}

class _ComunidadChip extends StatefulWidget {
  const _ComunidadChip({required this.seleccionada, required this.onChanged});
  final String? seleccionada;
  final ValueChanged<String?> onChanged;

  @override
  State<_ComunidadChip> createState() => _ComunidadChipState();
}

class _ComunidadChipState extends State<_ComunidadChip> {
  /// Stream cacheado — query fija, no depende de props.
  late final Stream<List<Map<String, dynamic>>> _comunidadesStream;

  @override
  void initState() {
    super.initState();
    _comunidadesStream = ps.db.watch(
      '''
      SELECT co.id, co.nombre, m.nombre AS mun
        FROM comunidades co
        JOIN municipios m ON m.id = co.municipio_id
       ORDER BY m.nombre, co.nombre
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _comunidadesStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Chip(label: Text('Error: ${snap.error}'));
        }
        final rows = snap.data!;
        String label = 'Comunidad';
        if (widget.seleccionada != null) {
          final sel = rows.where((r) => r['id'] == widget.seleccionada);
          if (sel.isNotEmpty) label = sel.first['nombre'] as String;
        }
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
            widget.onChanged(picked);
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

class _Lista extends StatefulWidget {
  const _Lista({
    required this.query,
    required this.cobradorFilter,
    required this.comunidadFilter,
    required this.soloMora,
    required this.soloSinCobrador,
    required this.filtroEstado,
    required this.diasGracia,
    required this.pageSize,
    required this.seleccionados,
    required this.onToggle,
    required this.loadingMore,
    required this.onLoadMore,
  });

  final String query;
  final String? cobradorFilter;
  final String? comunidadFilter;
  final bool soloMora;
  final bool soloSinCobrador;
  final _FiltroEstado filtroEstado;
  final int diasGracia;
  final int pageSize;
  final Set<String> seleccionados;
  final ValueChanged<String> onToggle;
  final bool loadingMore;
  final VoidCallback onLoadMore;

  @override
  State<_Lista> createState() => _ListaState();
}

class _ListaState extends State<_Lista> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void didUpdateWidget(_Lista old) {
    super.didUpdateWidget(old);
    // Solo recrear el stream si cambió algún param que afecta la SQL.
    // seleccionados/onToggle/loadingMore/onLoadMore NO tocan la query —
    // solo cambian el render de la lista, así que no disparan recreate.
    if (old.query != widget.query ||
        old.cobradorFilter != widget.cobradorFilter ||
        old.comunidadFilter != widget.comunidadFilter ||
        old.soloMora != widget.soloMora ||
        old.soloSinCobrador != widget.soloSinCobrador ||
        old.filtroEstado != widget.filtroEstado ||
        old.diasGracia != widget.diasGracia ||
        old.pageSize != widget.pageSize) {
      setState(() => _stream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    final where = <String>[
      if (widget.filtroEstado == _FiltroEstado.activos) 'c.activo = 1',
      if (widget.filtroEstado == _FiltroEstado.inactivos) 'c.activo = 0',
    ];
    // diasGracia se usa DOS veces en el SELECT (vencidas + en_gracia), en ese
    // orden. SQLite bindea posicional, así que va duplicado al inicio.
    final params = <Object?>[widget.diasGracia, widget.diasGracia];

    if (widget.query.isNotEmpty) {
      where.add(
          '(lower(c.nombre) LIKE ? OR lower(coalesce(c.cedula,\'\')) LIKE ? OR coalesce(c.telefono,\'\') LIKE ? OR lower(coalesce(c.codigo,\'\')) LIKE ? OR c.id IN (SELECT cliente_id FROM contratos WHERE lower(coalesce(codigo,\'\')) LIKE ?))');
      final like = '%${widget.query}%';
      // Para el campo teléfono, sanitizamos el query a sólo dígitos.
      // Razón: post-sprint del validator, los teléfonos se guardan sin
      // espacios ni guiones (`+50588888888`). Si el user busca
      // `"8888-8888"`, el LIKE raw no matchea. Strip a dígitos y matchea.
      // Si el query no tiene dígitos, dejamos el like raw (no matchea
      // teléfonos pero tampoco rompe nombre/cédula).
      final digits = sanitizePhoneForWhatsApp(widget.query);
      final likeTelefono = digits.isEmpty ? like : '%$digits%';
      params..add(like)..add(like)..add(likeTelefono)..add('%${widget.query.toLowerCase()}%')..add(like);
    }
    if (widget.cobradorFilter != null) {
      where.add('c.cobrador_id = ?');
      params.add(widget.cobradorFilter);
    }
    if (widget.comunidadFilter != null) {
      where.add('c.comunidad_id = ?');
      params.add(widget.comunidadFilter);
    }
    if (widget.soloSinCobrador) {
      where.add('c.cobrador_id IS NULL');
    }

    final having = widget.soloMora ? 'HAVING vencidas > 0' : '';

    // LIMIT al final de los params para que el binding sea posicional
    // correcto. SQLite no soporta named params en bindings de Dart.
    params.add(widget.pageSize);

    final sql = '''
      SELECT c.id, c.codigo, c.nombre, c.telefono, c.direccion_referencia,
             c.cobrador_id, c.activo,
             co.nombre AS cobrador_nombre,
             cm.nombre AS comunidad, m.nombre AS municipio,
             COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                                AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now')
                               THEN 1 ELSE 0 END), 0) AS vencidas,
             COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                                AND date(cu.fecha_vencimiento) < date('now')
                                AND date(cu.fecha_vencimiento, '+' || ? || ' days') >= date('now')
                               THEN 1 ELSE 0 END), 0) AS en_gracia,
             COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                                THEN cu.monto + COALESCE(cu.cargos_neto, 0) - cu.monto_pagado
                                ELSE 0 END), 0) AS saldo,
             (SELECT COUNT(*) FROM contratos ct
               WHERE ct.cliente_id = c.id
                 AND COALESCE(ct.estado, 'activo') = 'activo') AS contratos_activos
        FROM clientes c
   LEFT JOIN cobradores  co ON co.id = c.cobrador_id
   LEFT JOIN comunidades cm ON cm.id = c.comunidad_id
   LEFT JOIN municipios  m  ON m.id = cm.municipio_id
   LEFT JOIN cuotas      cu ON cu.cliente_id = c.id
       WHERE ${where.isEmpty ? '1=1' : where.join(' AND ')}
       GROUP BY c.id, c.codigo, c.nombre, c.telefono, c.direccion_referencia,
                c.cobrador_id, c.activo, co.nombre, cm.nombre, m.nombre
       $having
       ORDER BY c.nombre
       LIMIT ?
    ''';

    return ps.db.watch(sql, parameters: params);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.people_outline,
            titulo: 'Sin clientes',
            descripcion: 'Ajustá filtros o creá uno nuevo.',
          );
        }
        // Cargar más cuando trajimos exactamente pageSize rows — heurística
        // de "probablemente hay más". Si el total fuese múltiplo exacto del
        // page size, el último tap traerá 0 nuevos y desaparecerá el botón.
        // No queremos un COUNT(*) extra al server: caro y poco valor.
        final hayMas = rows.length >= widget.pageSize;
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: rows.length + (hayMas ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            if (i == rows.length) {
              return CargarMasButton(
                loading: widget.loadingMore,
                onPressed: widget.onLoadMore,
              );
            }
            final r = rows[i];
            final selected = widget.seleccionados.contains(r['id']);
            return _ClienteCard(
              row: r,
              selected: selected,
              onToggle: () => widget.onToggle(r['id'] as String),
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
    final enGracia = row['en_gracia'] as int? ?? 0;
    final contratos = row['contratos_activos'] as int? ?? 0;
    final saldo = (row['saldo'] as num? ?? 0).toDouble();
    final sinCobrador = row['cobrador_id'] == null;
    final inactivo = (row['activo'] as int? ?? 1) == 0;
    // Ámbar para "en gracia" (consistente con el color de la cuota en gracia).
    const ambar = Color(0xFFB45309);

    return Card(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
      child: InkWell(
        onTap: () => context.push('/admin/clientes/${row['id']}'),
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
                    if (row['codigo'] != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(row['codigo'] as String,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                              letterSpacing: 0.5,
                            )),
                      ),
                    Row(
                      children: [
                        Flexible(
                          child: Text(row['nombre'] as String,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: inactivo ? scheme.outline : null,
                                decoration: inactivo ? TextDecoration.lineThrough : null,
                              )),
                        ),
                        if (inactivo) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('Inactivo',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.outline)),
                          ),
                        ],
                      ],
                    ),
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
                        // Indicador de multi-contrato: que se vea de un vistazo
                        // que el cliente tiene más de un servicio (la mora y el
                        // saldo agregan todos los contratos).
                        if (contratos >= 2)
                          Chip(
                            avatar: Icon(Icons.description_outlined,
                                size: 14, color: scheme.primary),
                            label: Text('$contratos contratos'),
                            backgroundColor:
                                scheme.primaryContainer.withValues(alpha: 0.3),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (vencidas > 0)
                          Chip(
                            avatar: Icon(Icons.warning, size: 14, color: scheme.error),
                            label: Text('$vencidas vencida(s)'),
                            backgroundColor: scheme.errorContainer.withValues(alpha: 0.3),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (enGracia > 0)
                          Chip(
                            avatar: const Icon(Icons.hourglass_bottom,
                                size: 14, color: ambar),
                            label: Text('$enGracia en gracia'),
                            backgroundColor: ambar.withValues(alpha: 0.12),
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

class _SeleccionarCobradorDialog extends StatefulWidget {
  const _SeleccionarCobradorDialog();

  @override
  State<_SeleccionarCobradorDialog> createState() =>
      _SeleccionarCobradorDialogState();
}

class _SeleccionarCobradorDialogState
    extends State<_SeleccionarCobradorDialog> {
  /// Stream cacheado — query fija, no depende de props.
  late final Stream<List<Map<String, dynamic>>> _cobradoresStream;

  @override
  void initState() {
    super.initState();
    _cobradoresStream = ps.db.watch(
      '''
      SELECT id, nombre, prefijo_recibo FROM cobradores
       WHERE activo = 1 AND rol = 'cobrador'
       ORDER BY nombre
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Asignar cobrador'),
      content: SizedBox(
        width: 400,
        child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _cobradoresStream,
          initialData: const [],
          builder: (context, snap) {
            if (snap.hasError) {
              return SizedBox(
                  height: 100, child: Center(child: Text('Error: ${snap.error}')));
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



enum _FiltroEstado { activos, inactivos, todos }

extension _FiltroEstadoLabel on _FiltroEstado {
  String get label => switch (this) {
        _FiltroEstado.activos => "Solo activos",
        _FiltroEstado.inactivos => "Solo inactivos",
        _FiltroEstado.todos => "Todos",
      };
  IconData get icon => switch (this) {
        _FiltroEstado.activos => Icons.visibility,
        _FiltroEstado.inactivos => Icons.visibility_off,
        _FiltroEstado.todos => Icons.all_inclusive,
      };
}

class _EstadoFilterChip extends StatelessWidget {
  const _EstadoFilterChip({required this.value, required this.onChanged});
  final _FiltroEstado value;
  final ValueChanged<_FiltroEstado> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_FiltroEstado>(
      onSelected: onChanged,
      itemBuilder: (_) => _FiltroEstado.values
          .map((e) => PopupMenuItem(
                value: e,
                child: Row(
                  children: [
                    Icon(e.icon, size: 18),
                    const SizedBox(width: 8),
                    Text(e.label),
                  ],
                ),
              ))
          .toList(),
      child: Chip(
        avatar: Icon(value.icon, size: 18),
        label: Text(value.label),
        deleteIcon: const Icon(Icons.arrow_drop_down, size: 18),
        onDeleted: () {},
      ),
    );
  }
}
