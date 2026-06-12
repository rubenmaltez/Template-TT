import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/settings_repo.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/validators.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/cargar_mas_button.dart';
import '../shared/widgets/empty_state.dart';

class ClientesListScreen extends ConsumerStatefulWidget {
  const ClientesListScreen({super.key});

  @override
  ConsumerState<ClientesListScreen> createState() => _ClientesListScreenState();
}

/// Página inicial sin búsqueda activa. Increments del mismo tamaño
/// al tocar "Cargar más". El cobrador típico tiene <500 clientes
/// asignados — 50 cubre el primer screen sin paginar en uso normal.
const int _kPageSize = 50;

/// Página inicial con búsqueda activa. El WHERE LIKE ya reduce el
/// set y queremos retornar todos los matches realistas sin obligar
/// al cobrador a paginar dentro de su búsqueda.
const int _kSearchPageSize = 200;

class _ClientesListScreenState extends ConsumerState<ClientesListScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String? _comunidadFilter; // null = todas
  bool _soloConMora = false;
  Timer? _debounce;
  // Tamaño actual de la página. Se incrementa al tocar "Cargar más"
  // y se resetea a _kPageSize cuando cambia query/filtros.
  int _pageSize = _kPageSize;
  // True desde el tap "Cargar más" hasta que pase un debounce corto.
  // Anti-doble-tap; el SQLite local emite el snapshot nuevo en pocos
  // ms y el debounce de 400ms cubre el feedback visual del botón.
  bool _loadingMore = false;
  Timer? _loadingMoreTimer;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    _loadingMoreTimer?.cancel();
    super.dispose();
  }

  // Tamaño base según haya búsqueda o no. Cuando hay search, el
  // primer pintado y cada tap traen 200 — el cobrador no tiene que
  // paginar adentro de su búsqueda salvo casos muy genéricos.
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
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        setState(() {
          _query = value.trim().toLowerCase();
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _searchCtrl,
            onChanged: _onSearchChanged,
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
        _FiltersRow(
          comunidadActual: _comunidadFilter,
          soloConMora: _soloConMora,
          onComunidad: (v) => setState(() {
            _comunidadFilter = v;
            _resetPagination();
          }),
          onSoloMora: (v) => setState(() {
            _soloConMora = v;
            _resetPagination();
          }),
        ),
        Expanded(
          child: _ClientesList(
            query: _query,
            comunidadId: _comunidadFilter,
            soloConMora: _soloConMora,
            diasGracia: diasGracia,
            pageSize: _pageSize,
            loadingMore: _loadingMore,
            onLoadMore: _onLoadMore,
          ),
        ),
      ],
    );
  }
}

/// Fila de filtros: chip de comunidad (abre BottomSheet) + toggle "solo mora".
class _FiltersRow extends StatelessWidget {
  const _FiltersRow({
    required this.comunidadActual,
    required this.soloConMora,
    required this.onComunidad,
    required this.onSoloMora,
  });

  final String? comunidadActual;
  final bool soloConMora;
  final ValueChanged<String?> onComunidad;
  final ValueChanged<bool> onSoloMora;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _ComunidadChip(seleccionada: comunidadActual, onChanged: onComunidad),
          const SizedBox(width: 8),
          FilterChip(
            avatar: const Icon(Icons.warning_amber, size: 18),
            label: const Text('Solo en mora'),
            selected: soloConMora,
            onSelected: onSoloMora,
          ),
        ],
      ),
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
      SELECT co.id, co.nombre, m.nombre AS municipio
        FROM comunidades co
        JOIN municipios m ON m.id = co.municipio_id
       WHERE co.id IN (
         SELECT DISTINCT comunidad_id FROM clientes WHERE comunidad_id IS NOT NULL
       )
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
          return Chip(label: Text(mensajeErrorHumano(snap.error!)));
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
                      title: const Text('Todas las comunidades'),
                      onTap: () => Navigator.pop(ctx, null),
                    ),
                    const Divider(height: 1),
                    ...rows.map((r) => ListTile(
                          title: Text(r['nombre'] as String),
                          subtitle: Text(r['municipio'] as String),
                          onTap: () => Navigator.pop(ctx, r['id'] as String),
                        )),
                  ],
                ),
              ),
            );
            // ignore: use_build_context_synchronously
            widget.onChanged(picked);
          },
        );
      },
    );
  }
}

/// Query principal: clientes + comunidad + agregados de cuotas pendientes.
/// Hace JOINs locales (SQLite soporta a diferencia de sync rules).
class _ClientesList extends StatefulWidget {
  const _ClientesList({
    required this.query,
    required this.comunidadId,
    required this.soloConMora,
    required this.diasGracia,
    required this.pageSize,
    required this.loadingMore,
    required this.onLoadMore,
  });

  final String query;
  final String? comunidadId;
  final bool soloConMora;
  final int diasGracia;
  final int pageSize;
  final bool loadingMore;
  final VoidCallback onLoadMore;

  @override
  State<_ClientesList> createState() => _ClientesListState();
}

class _ClientesListState extends State<_ClientesList> {
  // Stream cacheado: se crea en initState y SOLO se recrea cuando cambian los
  // parámetros de la query (didUpdateWidget). Antes el ps.db.watch estaba inline
  // en build() → re-suscribía la query de PowerSync en cada rebuild del padre
  // (cambio de settings/filtros) y causaba flicker (anti-patrón del backlog).
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void didUpdateWidget(_ClientesList old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query ||
        old.comunidadId != widget.comunidadId ||
        old.soloConMora != widget.soloConMora ||
        old.diasGracia != widget.diasGracia ||
        old.pageSize != widget.pageSize) {
      _stream = _buildStream();
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    final like = '%${widget.query}%';
    // Para el campo teléfono, sanitizamos el query a sólo dígitos.
    // Razón: post-sprint del validator, los teléfonos se guardan sin
    // espacios ni guiones (`+50588888888`). Si el cobrador busca
    // `"8888-8888"` en campo, el LIKE raw no matchea. Strip a dígitos
    // y matchea. Si el query no tiene dígitos, dejamos el like raw
    // (no matchea teléfonos pero tampoco rompe nombre/cédula).
    final digits = sanitizePhoneForWhatsApp(widget.query);
    final likeTelefono = digits.isEmpty ? like : '%$digits%';
    final params = <Object?>[widget.diasGracia];
    final where = <String>['c.activo = 1'];

    if (widget.query.isNotEmpty) {
      where.add('(lower(c.nombre) LIKE ? OR c.cedula LIKE ? OR c.telefono LIKE ? OR lower(coalesce(c.codigo,\'\')) LIKE ? OR c.id IN (SELECT cliente_id FROM contratos WHERE lower(coalesce(codigo,\'\')) LIKE ?))');
      params..add(like)..add(like)..add(likeTelefono)..add(like)..add(like);
    }
    if (widget.comunidadId != null) {
      where.add('c.comunidad_id = ?');
      params.add(widget.comunidadId);
    }

    final having = widget.soloConMora ? 'HAVING cuotas_vencidas > 0' : '';

    // LIMIT al final de los params para binding posicional.
    params.add(widget.pageSize);

    final sql = '''
      SELECT
        c.id, c.codigo, c.nombre, c.telefono, c.direccion_referencia,
        co.nombre  AS comunidad,
        m.nombre   AS municipio,
        c.latitud, c.longitud,
        COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial') THEN 1 ELSE 0 END), 0) AS cuotas_pendientes,
        COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
            AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now', '-6 hours')
          THEN 1 ELSE 0 END), 0) AS cuotas_vencidas,
        COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                          THEN max(cu.monto + COALESCE(cu.cargos_neto, 0) - cu.monto_pagado, 0)
                          ELSE 0 END), 0) AS saldo,
        (SELECT COUNT(*) FROM contratos ct
          WHERE ct.cliente_id = c.id
            AND COALESCE(ct.estado, 'activo') = 'activo') AS contratos_activos
        FROM clientes c
        LEFT JOIN comunidades co ON co.id = c.comunidad_id
        LEFT JOIN municipios  m  ON m.id = co.municipio_id
        LEFT JOIN cuotas      cu ON cu.cliente_id = c.id
       WHERE ${where.join(' AND ')}
       GROUP BY c.id, c.codigo, c.nombre, c.telefono, c.direccion_referencia,
                co.nombre, m.nombre, c.latitud, c.longitud
       $having
       ORDER BY cuotas_vencidas DESC, cuotas_pendientes DESC, c.nombre
       LIMIT ?
    ''';

    return ps.db.watch(sql, parameters: params);
  }

  @override
  Widget build(BuildContext context) {
    final query = widget.query;
    final comunidadId = widget.comunidadId;
    final soloConMora = widget.soloConMora;
    final pageSize = widget.pageSize;
    final loadingMore = widget.loadingMore;
    final onLoadMore = widget.onLoadMore;

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text(mensajeErrorHumano(snap.error!)));
        }
        // M11: sin initialData, el primer frame muestra carga en vez de
        // flashear el estado vacío antes de que llegue la data real.
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final rows = snap.data ?? const [];
        if (rows.isEmpty) {
          return EmptyState(
            icon: Icons.person_off_outlined,
            titulo: query.isEmpty && comunidadId == null && !soloConMora
                ? 'No tenés clientes asignados'
                : 'Sin resultados',
            descripcion: 'Probá ajustar los filtros.',
          );
        }
        // "Probablemente hay más" si trajimos exactamente pageSize rows.
        // En el último tap puede traer 0 nuevos y desaparece el botón.
        final hayMas = rows.length >= pageSize;
        return ListView.builder(
          itemCount: rows.length + (hayMas ? 1 : 0),
          padding: const EdgeInsets.only(bottom: 80),
          itemBuilder: (_, i) {
            if (i == rows.length) {
              return CargarMasButton(
                loading: loadingMore,
                onPressed: onLoadMore,
              );
            }
            return _ClienteCard(row: rows[i]);
          },
        );
      },
    );
  }
}

class _ClienteCard extends StatelessWidget {
  const _ClienteCard({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vencidas = (row['cuotas_vencidas'] as int? ?? 0);
    final pendientes = (row['cuotas_pendientes'] as int? ?? 0);
    final contratos = (row['contratos_activos'] as int? ?? 0);
    final saldo = (row['saldo'] as num? ?? 0).toDouble();
    final tieneMora = vencidas > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.push('/clientes/${row['id']}'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: tieneMora ? scheme.errorContainer : scheme.primaryContainer,
                  foregroundColor: tieneMora ? scheme.onErrorContainer : scheme.onPrimaryContainer,
                  child: Text(_initials(row['nombre'] as String)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (row['codigo'] != null)
                        Text(row['codigo'] as String,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                                color: scheme.primary,
                                letterSpacing: 0.5)),
                      Text(row['nombre'] as String,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (row['comunidad'] != null) row['comunidad'],
                          if (row['municipio'] != null) row['municipio'],
                        ].join(' · '),
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                      ),
                      if (row['direccion_referencia'] != null &&
                          (row['direccion_referencia'] as String).isNotEmpty)
                        Text(
                          row['direccion_referencia'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.outline, fontSize: 12),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          // Indicador de multi-contrato: que se vea de un vistazo
                          // que el cliente tiene más de un servicio (la mora y el
                          // saldo agregan todos los contratos).
                          if (contratos >= 2)
                            _MiniChip(
                              icon: Icons.description_outlined,
                              label: '$contratos contratos',
                              color: scheme.primary,
                            ),
                          if (tieneMora)
                            _MiniChip(
                              icon: Icons.warning,
                              label: '$vencidas vencida${vencidas == 1 ? '' : 's'}',
                              color: scheme.error,
                            ),
                          if (pendientes > 0 && !tieneMora)
                            _MiniChip(
                              icon: Icons.pending_actions,
                              label: '$pendientes pendiente${pendientes == 1 ? '' : 's'}',
                              color: scheme.primary,
                            ),
                          if (pendientes == 0)
                            _MiniChip(
                              icon: Icons.check_circle,
                              label: 'Al día',
                              color: scheme.tertiary,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      Fmt.cordobas(saldo),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: tieneMora ? scheme.error : null,
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
      ),
    );
  }

  String _initials(String nombre) {
    final parts = nombre.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }
}
