import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/cuotas_filtro_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/cuota_estado_visual.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/dropdown_filtro.dart';
import '../shared/widgets/empty_state.dart';

enum _Filtro { todas, mora, gracia, parciales, hoy, proxima, verTodo }

/// Pantalla de Cobros. La usa el cobrador (móvil-first, su vista de trabajo)
/// y el admin en modo monitoreo (`adminMode: true`).
///
/// En `adminMode` el admin SE QUEDA en esta pantalla (no se aplica el
/// safety-net que reencamina admins a /admin) y aparecen dos filtros
/// chip-dropdown ("Cobrador" / "Zona") para acotar por el cobrador y la
/// comunidad de los clientes — mismo patrón visual que el mapa. El cobrador
/// (adminMode false) ve la pantalla intacta: sin dropdowns, con su
/// safety-net activo.
class CuotasListScreen extends ConsumerStatefulWidget {
  const CuotasListScreen({super.key, this.adminMode = false});

  /// Cuando true, habilita la vista admin: filtros por cobrador/zona y sin
  /// el redirect automático de admins a /admin.
  final bool adminMode;

  @override
  ConsumerState<CuotasListScreen> createState() => _CuotasListScreenState();
}

class _CuotasListScreenState extends ConsumerState<CuotasListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  _Filtro _filtro = _Filtro.todas;

  final Set<String> _selected = {};
  String? _selectedContratoId;

  // Filtros admin (null = todos/todas). Sólo se usan/mostran en adminMode.
  String? _cobradorId;
  String? _comunidadId;

  // Streams de opciones de los dropdowns (sólo adminMode). Cacheados en
  // initState para no recrear suscripciones en cada build (anti-patrón
  // ps.db.watch inline). Cobradores activos del tenant + comunidades con
  // clientes activos.
  late final Stream<List<Map<String, dynamic>>> _cobradorOpcionesStream;
  late final Stream<List<Map<String, dynamic>>> _comunidadOpcionesStream;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) _clearSelection();
    });
    if (widget.adminMode) {
      // Cobradores activos del tenant (rol cobrador). RLS scopa por tenant.
      _cobradorOpcionesStream = ps.db.watch('''
        SELECT id, nombre
          FROM cobradores
         WHERE rol = 'cobrador' AND activo = 1
         ORDER BY nombre
      ''');
      // Comunidades que tienen al menos un cliente activo asignado.
      _comunidadOpcionesStream = ps.db.watch('''
        SELECT co.id AS id, co.nombre AS nombre
          FROM comunidades co
          JOIN clientes c ON c.comunidad_id = co.id AND c.activo = 1
         GROUP BY co.id, co.nombre
         ORDER BY co.nombre
      ''');
    }
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _marcarMoraComoVista() async {
    // vista_por es uuid FK a cobradores(id): hay que escribir el id del
    // cobrador, NUNCA el literal 'cobrador' — rompía el sync con "invalid
    // input syntax for type uuid". Este UPDATE marca las no-vistas Y repara
    // las que el bug previo dejó con el literal, reescribiendo un uuid válido.
    final cobradorId = ref.read(cobradorActualProvider).valueOrNull?.id;
    if (cobradorId == null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    await ps.db.execute('''
      UPDATE notificaciones_mora
      SET vista_en = COALESCE(vista_en, ?), vista_por = ?
      WHERE resuelta_en IS NULL
        AND (vista_en IS NULL OR vista_por = 'cobrador')
    ''', [now, cobradorId]);
  }

  void _toggleSelect(String cuotaId, String? contratoId, [List<String>? orderedIds]) {
    if (contratoId == null) return;
    setState(() {
      if (_selected.contains(cuotaId)) {
        if (orderedIds != null) {
          final idx = orderedIds.indexOf(cuotaId);
          for (var i = idx; i < orderedIds.length; i++) {
            _selected.remove(orderedIds[i]);
          }
        } else {
          _selected.remove(cuotaId);
        }
        if (_selected.isEmpty) _selectedContratoId = null;
      } else {
        if (_selected.isEmpty) {
          _selectedContratoId = contratoId;
          _selected.add(cuotaId);
        } else if (contratoId == _selectedContratoId) {
          if (orderedIds != null) {
            final idx = orderedIds.indexOf(cuotaId);
            if (idx == 0 || (idx > 0 && _selected.contains(orderedIds[idx - 1]))) {
              _selected.add(cuotaId);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Debés cobrar las cuotas anteriores primero'),
                  duration: Duration(seconds: 2),
                ),
              );
            }
          } else {
            _selected.add(cuotaId);
          }
        }
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
      _selectedContratoId = null;
    });
  }

  /// Convierte las filas de un stream de opciones (id/nombre) al formato de
  /// records que espera `DropdownFiltro`. Filas con id null se ignoran.
  List<({String id, String label})> _opciones(
    List<Map<String, dynamic>> rows,
  ) {
    final out = <({String id, String label})>[];
    for (final r in rows) {
      final id = r['id'] as String?;
      if (id == null) continue;
      out.add((id: id, label: (r['nombre'] as String?) ?? id));
    }
    return out;
  }

  /// Fila de dos chip-dropdowns ("Cobrador" / "Zona") para la vista admin.
  /// Cada uno se alimenta de su stream cacheado en initState. null = todos /
  /// todas. Mismo widget compartido (`DropdownFiltro`) que usa el mapa.
  Widget _buildFiltrosAdmin() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _cobradorOpcionesStream,
            initialData: const [],
            builder: (context, snap) => DropdownFiltro(
              icon: Icons.person_outline,
              hint: 'Cobrador',
              todosLabel: 'Todos',
              value: _cobradorId,
              opciones: _opciones(snap.data ?? const []),
              onChanged: (v) {
                setState(() => _cobradorId = v);
                _clearSelection();
              },
            ),
          ),
          const SizedBox(width: 8),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _comunidadOpcionesStream,
            initialData: const [],
            builder: (context, snap) => DropdownFiltro(
              icon: Icons.place_outlined,
              hint: 'Zona',
              todosLabel: 'Todas',
              value: _comunidadId,
              opciones: _opciones(snap.data ?? const []),
              onChanged: (v) {
                setState(() => _comunidadId = v);
                _clearSelection();
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);

    // Safety-net del cold-start: '/' (= Cobros) es la landing del cobrador.
    // Si el router aún no resolvió el rol y un admin/admin_cobranza/super_admin
    // cayó acá, lo reencaminamos a /admin cuando llega su rol. Redundante con el
    // redirect del router, pero evita el flash de la pantalla del cobrador
    // (paridad con el viejo HomeScreen eliminado).
    //
    // En adminMode NO aplica: el admin entra a propósito a /admin/cobros y
    // debe quedarse acá (esta MISMA pantalla es su vista de monitoreo).
    if (!widget.adminMode) {
      final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
      if ((cobrador != null && cobrador.tieneAccesoAdmin) ||
          cobrador?.esAdminCobranza == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) context.go('/admin');
        });
      }
    }

    final diasGracia = settings.diasGracia;
    final diasVisibles = settings.diasCuotasVisibles;
    final multiCuotaEnabled = settings.pagoAdelantadoPermitido;
    final scheme = Theme.of(context).colorScheme;

    // El filtro "Parciales" se muestra si el tenant permite pago parcial O si ya
    // hay cuotas parciales (históricas). Si queda oculto y estaba activo, se
    // vuelve a 'todas'.
    final mostrarParcial = settings.pagoParcialPermitido ||
        (ref.watch(hayCuotasParcialesProvider).valueOrNull ?? false);
    if (!mostrarParcial && _filtro == _Filtro.parciales) {
      _filtro = _Filtro.todas;
    }
    // "Ver todo" (sin límite de rango) es exclusivo del admin. Si el cobrador
    // quedara con ese filtro (no debería: el chip no se le muestra), vuelve a
    // 'todas'.
    if (!widget.adminMode && _filtro == _Filtro.verTodo) {
      _filtro = _Filtro.todas;
    }

    return Stack(
      children: [
        Column(
          children: [
            // Filtros admin (cobrador / zona) — sólo en adminMode. Mismo
            // look chip-dropdown del mapa (DropdownFiltro compartido).
            if (widget.adminMode) _buildFiltrosAdmin(),
            Material(
              color: scheme.surface,
              child: TabBar(
                controller: _tabCtrl,
                labelColor: scheme.primary,
                unselectedLabelColor: scheme.outline,
                indicatorColor: scheme.primary,
                tabs: const [
                  Tab(icon: Icon(Icons.people, size: 18), text: 'Por cliente'),
                  Tab(icon: Icon(Icons.receipt_long, size: 18), text: 'Por cobrar'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  // Tab A: Por cliente (default — la vista de trabajo del cobrador)
                  _TabPorCliente(
                    cobradorId: widget.adminMode ? _cobradorId : null,
                    comunidadId: widget.adminMode ? _comunidadId : null,
                  ),
                  // Tab B: Por cobrar (con filtros + multi-select)
                  _TabPorCobrar(
                    filtro: _filtro,
                    mostrarParcial: mostrarParcial,
                    adminMode: widget.adminMode,
                    diasGracia: diasGracia,
                    diasVisibles: diasVisibles,
                    multiSelect: multiCuotaEnabled,
                    selected: _selected,
                    selectedContratoId: _selectedContratoId,
                    onToggle: _toggleSelect,
                    cobradorId: widget.adminMode ? _cobradorId : null,
                    comunidadId: widget.adminMode ? _comunidadId : null,
                    onFiltroChanged: (f) {
                      setState(() => _filtro = f);
                      _clearSelection();
                      if (f == _Filtro.mora) _marcarMoraComoVista();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_selected.isNotEmpty)
          Positioned(
            left: 16, right: 16, bottom: 16,
            child: Row(
              children: [
                IconButton.filledTonal(
                  icon: const Icon(Icons.close),
                  onPressed: _clearSelection,
                  tooltip: 'Cancelar selección',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.payment),
                    label: Text(_selected.length == 1
                        ? 'Cobrar cuota'
                        : 'Cobrar ${_selected.length} cuotas'),
                    onPressed: () {
                      final ids = _selected.join(',');
                      _clearSelection();
                      context.push('/cobro/$ids');
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab A: Por cobrar
// ─────────────────────────────────────────────────────────────────────────────

class _TabPorCobrar extends StatelessWidget {
  const _TabPorCobrar({
    required this.filtro,
    required this.mostrarParcial,
    required this.adminMode,
    required this.diasGracia,
    required this.diasVisibles,
    required this.multiSelect,
    required this.selected,
    required this.selectedContratoId,
    required this.onToggle,
    required this.onFiltroChanged,
    this.cobradorId,
    this.comunidadId,
  });
  final _Filtro filtro;
  final bool mostrarParcial;
  final bool adminMode;
  final int diasGracia;
  final int diasVisibles;
  final bool multiSelect;
  final Set<String> selected;
  final String? selectedContratoId;
  final void Function(String cuotaId, String? contratoId, [List<String>? orderedIds]) onToggle;
  final ValueChanged<_Filtro> onFiltroChanged;
  // Filtros admin (null = sin filtrar). En la vista del cobrador siempre null.
  final String? cobradorId;
  final String? comunidadId;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              for (final f in _Filtro.values)
                if ((mostrarParcial || f != _Filtro.parciales) &&
                    (adminMode || f != _Filtro.verTodo)) ...[
                  FilterChip(
                    label: Text(_label(f)),
                    selected: filtro == f,
                    onSelected: (_) => onFiltroChanged(f),
                  ),
                  const SizedBox(width: 8),
                ],
            ],
          ),
        ),
        Expanded(
          child: _CuotasList(
            filtro: filtro,
            diasGracia: diasGracia,
            diasVisibles: diasVisibles,
            multiSelect: multiSelect,
            selected: selected,
            selectedContratoId: selectedContratoId,
            onToggle: onToggle,
            cobradorId: cobradorId,
            comunidadId: comunidadId,
          ),
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
        _Filtro.proxima => 'Próximas',
        _Filtro.verTodo => 'Ver todo',
      };
}

class _CuotasList extends StatefulWidget {
  const _CuotasList({
    required this.filtro,
    required this.diasGracia,
    required this.diasVisibles,
    required this.multiSelect,
    required this.selected,
    required this.selectedContratoId,
    required this.onToggle,
    this.cobradorId,
    this.comunidadId,
  });
  final _Filtro filtro;
  final int diasGracia;
  final int diasVisibles;
  final bool multiSelect;
  final Set<String> selected;
  final String? selectedContratoId;
  final void Function(String cuotaId, String? contratoId, [List<String>? orderedIds]) onToggle;
  // Filtros admin (null = sin filtrar). En la vista del cobrador siempre null.
  final String? cobradorId;
  final String? comunidadId;

  @override
  State<_CuotasList> createState() => _CuotasListState();
}

class _CuotasListState extends State<_CuotasList> {
  late Stream<List<Map<String, dynamic>>> _cuotasStream;

  @override
  void initState() {
    super.initState();
    _cuotasStream = _buildStream();
  }

  @override
  void didUpdateWidget(_CuotasList old) {
    super.didUpdateWidget(old);
    if (old.filtro != widget.filtro ||
        old.diasGracia != widget.diasGracia ||
        old.diasVisibles != widget.diasVisibles ||
        old.cobradorId != widget.cobradorId ||
        old.comunidadId != widget.comunidadId) {
      setState(() => _cuotasStream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    // "Hoy" en hora LOCAL del dispositivo, idéntico al que usan los badges de
    // la fila (DateTime.now() local). SQLite date('now') es UTC: en zonas como
    // Nicaragua (UTC-6) de noche difiere un día → "Vencen hoy" no matcheaba y
    // los rangos quedaban corridos. Pasamos el día local como parámetro para
    // que TODOS los filtros coincidan con lo que ve el cobrador.
    // Día de HOY en hora de Nicaragua (UTC-6, sin DST): date('now','-6 hours').
    // NUNCA date('now') pelado (es UTC → corre 1 día de noche). Norma general
    // de la app para lógica de límite de día — ver CLAUDE.md.
    final rangoFilter = widget.filtro == _Filtro.todas
        ? "AND cu.estado IN ('pendiente','parcial') "
            "AND date(cu.fecha_vencimiento) <= date('now', '-6 hours', '+${widget.diasVisibles} days')"
        : '';

    final (String extra, List<Object?> params) = switch (widget.filtro) {
      _Filtro.todas => (rangoFilter, <Object?>[]),
      _Filtro.mora => (
          "AND cu.estado IN ('pendiente','parcial') "
              "AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now', '-6 hours')",
          <Object?>[widget.diasGracia],
        ),
      _Filtro.gracia => (
          "AND cu.estado IN ('pendiente','parcial') "
              "AND date(cu.fecha_vencimiento) < date('now', '-6 hours') "
              "AND date(cu.fecha_vencimiento, '+' || ? || ' days') >= date('now', '-6 hours')",
          <Object?>[widget.diasGracia],
        ),
      _Filtro.parciales => ("AND cu.estado = 'parcial'", <Object?>[]),
      _Filtro.hoy => (
          "AND cu.estado IN ('pendiente','parcial') "
              "AND date(cu.fecha_vencimiento) = date('now', '-6 hours')",
          <Object?>[],
        ),
      // Próximas: vencen DESPUÉS de hoy pero dentro del rango visible. "Hoy" es
      // su propio filtro (exclusivo de la fecha de hoy), así que acá es > hoy.
      _Filtro.proxima => (
          "AND cu.estado IN ('pendiente','parcial') "
              "AND date(cu.fecha_vencimiento) > date('now', '-6 hours') "
              "AND date(cu.fecha_vencimiento) <= date('now', '-6 hours', '+${widget.diasVisibles} days')",
          <Object?>[],
        ),
      // Ver todo (solo admin): TODO lo pendiente, SIN el límite de rango — la
      // forma del admin de ver las cuotas fuera de rango que el cobrador no ve.
      _Filtro.verTodo => ("AND cu.estado IN ('pendiente','parcial')", <Object?>[]),
    };

    final orderBy = widget.filtro == _Filtro.mora
        ? 'ORDER BY co.nombre, c.nombre'
        : 'ORDER BY cu.fecha_vencimiento ASC, c.nombre';

    // Filtros admin (cobrador / zona). Se acumulan después de los params del
    // filtro de estado para preservar el orden posicional de los `?`. En la
    // vista del cobrador ambos son null y no agregan condiciones.
    final allParams = <Object?>[...params];
    var adminFilter = '';
    if (widget.cobradorId != null) {
      adminFilter += 'AND c.cobrador_id = ? ';
      allParams.add(widget.cobradorId);
    }
    if (widget.comunidadId != null) {
      adminFilter += 'AND c.comunidad_id = ? ';
      allParams.add(widget.comunidadId);
    }

    final sql = '''
      SELECT cu.id, cu.monto, cu.monto_pagado, cu.fecha_vencimiento,
             cu.periodo, cu.estado, cu.contrato_id,
             cu.descripcion, cu.tipo_cargo_manual,
             COALESCE(cu.cargos_neto, 0) AS cargos_neto,
             c.id AS cliente_id, c.nombre AS cliente_nombre,
             co.nombre AS comunidad,
             p.nombre AS plan_nombre, ct.dia_pago
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN comunidades co ON co.id = c.comunidad_id
   LEFT JOIN contratos ct ON ct.id = cu.contrato_id
   LEFT JOIN planes p ON p.id = ct.plan_id
       WHERE c.activo = 1
         $extra
         $adminFilter
       $orderBy
    ''';

    return ps.db.watch(sql, parameters: allParams);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cuotasStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.check_circle_outline,
            titulo: 'Nada por cobrar',
            descripcion: 'No hay cuotas que coincidan con el filtro.',
          );
        }

        // Agrupar por cliente_id para card-per-client.
        final byClient = <String, List<Map<String, dynamic>>>{};
        final clientOrder = <String>[];
        for (final r in rows) {
          final cid = r['cliente_id'] as String;
          if (!byClient.containsKey(cid)) {
            byClient[cid] = [];
            clientOrder.add(cid);
          }
          byClient[cid]!.add(r);
        }

        return ListView.builder(
          padding: EdgeInsets.only(
            left: 8, right: 8, top: 8,
            bottom: widget.selected.isNotEmpty ? 80 : 16,
          ),
          itemCount: clientOrder.length,
          itemBuilder: (context, i) {
            final cid = clientOrder[i];
            final cuotas = byClient[cid]!;
            final first = cuotas.first;
            final clienteNombre = first['cliente_nombre'] as String;
            final comunidad = first['comunidad'] as String?;

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header del cliente
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      children: [
                        Icon(Icons.person, size: 18,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(clienteNombre,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  )),
                              if (comunidad != null)
                                Text(comunidad,
                                    style: TextStyle(
                                      color: Theme.of(context).colorScheme.outline,
                                      fontSize: 11,
                                    )),
                            ],
                          ),
                        ),
                        Text('${cuotas.length} cuota(s)',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.outline,
                              fontSize: 11,
                            )),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  // Cuotas compactas — computar IDs pendientes ordenados
                  // para validar orden de pago por contrato.
                  ...() {
                    // Agrupar cuotas pendientes por contrato para orden.
                    final pendingByContrato = <String?, List<String>>{};
                    for (final c in cuotas) {
                      final e = c['estado'] as String;
                      if (e == 'pendiente' || e == 'parcial') {
                        final ctId = c['contrato_id'] as String?;
                        pendingByContrato.putIfAbsent(ctId, () => []);
                        pendingByContrato[ctId]!.add(c['id'] as String);
                      }
                    }

                    return cuotas.map((row) {
                      final cuotaId = row['id'] as String;
                      final contratoId = row['contrato_id'] as String?;
                      final isSelected = widget.selected.contains(cuotaId);
                      final pendingIds = pendingByContrato[contratoId] ?? [];
                      final canSelect = widget.multiSelect &&
                          (widget.selected.isEmpty ||
                              contratoId == widget.selectedContratoId);

                      return _CuotaCompactRow(
                        row: row,
                        diasGracia: widget.diasGracia,
                        isSelected: isSelected,
                        showCheckbox: widget.selected.isNotEmpty,
                        onTap: () {
                          if (widget.selected.isNotEmpty) {
                            widget.onToggle(cuotaId, contratoId, pendingIds);
                          } else {
                            context.push('/cobro/$cuotaId');
                          }
                        },
                        onLongPress: widget.multiSelect && canSelect
                            ? () => widget.onToggle(cuotaId, contratoId, pendingIds)
                            : null,
                      );
                    });
                  }(),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab B: Por cliente
// ─────────────────────────────────────────────────────────────────────────────

class _TabPorCliente extends StatefulWidget {
  const _TabPorCliente({this.cobradorId, this.comunidadId});

  // Filtros admin (null = sin filtrar). En la vista del cobrador siempre null.
  final String? cobradorId;
  final String? comunidadId;

  @override
  State<_TabPorCliente> createState() => _TabPorClienteState();
}

class _TabPorClienteState extends State<_TabPorCliente> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void didUpdateWidget(_TabPorCliente old) {
    super.didUpdateWidget(old);
    if (old.cobradorId != widget.cobradorId ||
        old.comunidadId != widget.comunidadId) {
      setState(() => _stream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    // Filtros admin (cobrador / zona). Acumulan condiciones + params; en la
    // vista del cobrador ambos son null y la query queda como estaba.
    final params = <Object?>[];
    var adminFilter = '';
    if (widget.cobradorId != null) {
      adminFilter += 'AND c.cobrador_id = ? ';
      params.add(widget.cobradorId);
    }
    if (widget.comunidadId != null) {
      adminFilter += 'AND c.comunidad_id = ? ';
      params.add(widget.comunidadId);
    }

    return ps.db.watch('''
      SELECT c.id, c.nombre,
             co.nombre AS comunidad,
             COUNT(cu.id) AS cuotas_pend,
             SUM(CASE WHEN date(cu.fecha_vencimiento) < date('now', '-6 hours')
                      THEN 1 ELSE 0 END) AS cuotas_vencidas,
             COALESCE(SUM(max(cu.monto + COALESCE(cu.cargos_neto, 0) - cu.monto_pagado, 0)), 0) AS saldo_pendiente,
             MIN(cu.fecha_vencimiento) AS vence_mas_vieja
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN comunidades co ON co.id = c.comunidad_id
       WHERE cu.estado IN ('pendiente','parcial')
         AND c.activo = 1
         $adminFilter
       GROUP BY c.id
       ORDER BY MIN(cu.fecha_vencimiento) ASC, c.nombre
    ''', parameters: params);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.check_circle_outline,
            titulo: 'Sin clientes con deuda',
            descripcion: 'Todos los clientes están al día.',
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(8),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: 4),
          itemBuilder: (context, i) {
            final r = rows[i];
            final cuotasPend = (r['cuotas_pend'] as num).toInt();
            final cuotasVencidas = (r['cuotas_vencidas'] as num).toInt();
            final saldo = (r['saldo_pendiente'] as num).toDouble();
            final vence = DateTime.parse(r['vence_mas_vieja'] as String);
            // Día Nicaragua (B11) truncado, para coincidir con el corte SQL.
            final diasMora = Fmt.hoyNicaragua()
                .difference(DateTime(vence.year, vence.month, vence.day))
                .inDays;
            final enMora = diasMora > 0;

            return Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: enMora
                      ? scheme.errorContainer
                      : scheme.primaryContainer,
                  child: Icon(
                    Icons.person,
                    color: enMora ? scheme.error : scheme.primary,
                  ),
                ),
                title: Text(r['nombre'] as String),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r['comunidad'] as String? ?? 'Sin comunidad',
                      style: TextStyle(color: scheme.outline, fontSize: 12),
                    ),
                    Text(
                      enMora
                          ? '$cuotasVencidas vencida(s) · $diasMora día(s) en mora'
                          : '$cuotasPend cuota(s) pendiente(s)',
                      style: TextStyle(
                        color: enMora ? scheme.error : scheme.outline,
                        fontWeight: enMora ? FontWeight.w500 : null,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                trailing: Text(
                  Fmt.cordobas(saldo),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: enMora ? scheme.error : null,
                  ),
                ),
                onTap: () => context.push('/clientes/${r['id']}'),
              ),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared widgets
// ─────────────────────────────────────────────────────────────────────────────

class _CuotaCompactRow extends ConsumerWidget {
  const _CuotaCompactRow({
    required this.row,
    required this.diasGracia,
    required this.isSelected,
    required this.showCheckbox,
    required this.onTap,
    this.onLongPress,
  });
  final Map<String, dynamic> row;
  final int diasGracia;
  final bool isSelected;
  final bool showCheckbox;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  static String _tipoLabel(String tipo) => switch (tipo) {
        'reconexion' => 'Reconexión',
        'instalacion' => 'Instalación',
        'mora' => 'Mora',
        'reparacion' => 'Reparación',
        'otro' => 'Otro',
        _ => tipo,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(appSettingsProvider);
    final colores = settings.coloresEstados;
    final diasVisibles = settings.diasCuotasVisibles;
    final vence = DateTime.parse(row['fecha_vencimiento'] as String);
    final periodo = DateTime.parse(row['periodo'] as String);
    // Saldo canónico (regla #10): incluye cargos_neto (reconexión suma, descuento
    // resta). Sin esto, la lista "Por cobrar" mostraba un saldo distinto al de la
    // pantalla de cobro, el recibo y la tab "Por cliente".
    final saldoRaw = (row['monto'] as num).toDouble() +
        (row['cargos_neto'] as num? ?? 0).toDouble() -
        (row['monto_pagado'] as num? ?? 0).toDouble();
    final saldo = saldoRaw < 0 ? 0.0 : saldoRaw;
    final diasFromVence = Fmt.hoyNicaragua()
        .difference(DateTime(vence.year, vence.month, vence.day))
        .inDays;
    final esManual = row['contrato_id'] == null;

    final ev = estadoVisualCuota(
      diasFromVence: diasFromVence,
      diasGracia: diasGracia,
      diasVisibles: diasVisibles,
    );
    final color = colores.color(ev);
    final label = switch (ev) {
      CuotaEstadoVisual.mora => 'Vencida ${diasFromVence - diasGracia}d',
      CuotaEstadoVisual.gracia => 'Gracia',
      CuotaEstadoVisual.hoy => 'Hoy',
      // proxima / fueraDeRango (esta gris): días hasta el vencimiento.
      _ => '${-diasFromVence}d',
    };

    // Mes de servicio (mes con más días del período de la cuota). Cargos
    // manuales y cuotas sin contrato → mes del periodo tal cual.
    final mesLabel = Fmt.mesServicioLabel(
      periodo,
      (esManual || row['tipo_cargo_manual'] != null)
          ? null
          : (row['dia_pago'] as num?)?.toInt(),
    );

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: isSelected ? scheme.primaryContainer.withValues(alpha: 0.3) : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            if (showCheckbox)
              Checkbox(
                value: isSelected,
                onChanged: (_) => onTap(),
                visualDensity: VisualDensity.compact,
              )
            else
              SizedBox(
                width: 8,
                child: Container(
                  width: 4,
                  height: 24,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            const SizedBox(width: 8),
            // Mes + fecha
            SizedBox(
              width: 90,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mesLabel,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  Text(Fmt.fechaCorta(vence),
                      style: TextStyle(fontSize: 10, color: scheme.outline)),
                ],
              ),
            ),
            // Estado
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(label,
                  style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
            ),
            // Badges manuales
            if (esManual) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('Manual',
                    style: TextStyle(fontSize: 9, color: scheme.onTertiaryContainer)),
              ),
              if (row['tipo_cargo_manual'] != null) ...[
                const SizedBox(width: 3),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _tipoLabel(row['tipo_cargo_manual'] as String),
                    style: TextStyle(fontSize: 9, color: scheme.onPrimaryContainer),
                  ),
                ),
              ],
            ],
            const Spacer(),
            // Monto
            Text(Fmt.cordobas(saldo),
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

// Dead code removed: _ContratoHeader + _CuotaListTile (~150 lines)
// Reemplazados por _CuotaCompactRow + card-per-client inline header.
