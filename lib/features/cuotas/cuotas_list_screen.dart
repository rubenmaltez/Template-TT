import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/cuotas_filtro_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/cuota_estado_visual.dart';
import '../../data/utils/errores.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/dropdown_filtro.dart';
import '../shared/widgets/empty_state.dart';

enum _Filtro { todas, mora, gracia, parciales, hoy, proxima, verTodo }

/// Pantalla de Cobros ("Por cobrar"). La usa el cobrador (móvil-first, su vista
/// de trabajo) y el admin/admin_cobranza (`adminMode: true`).
///
/// Muestra UNA fila por contrato = su cuota MÁS ANTIGUA pendiente (igual que el
/// pin del mapa), con botón "Pagar" que va directo al cobro de esa cuota. Tocar
/// la fila abre el detalle del cliente. Tiene buscador de clientes + (en
/// adminMode) filtros chip-dropdown Cobrador/Zona + los chips de estado.
class CuotasListScreen extends ConsumerStatefulWidget {
  const CuotasListScreen({super.key, this.adminMode = false});

  /// Cuando true, habilita la vista admin: filtros por cobrador/zona y sin
  /// el redirect automático de admins a /admin.
  final bool adminMode;

  @override
  ConsumerState<CuotasListScreen> createState() => _CuotasListScreenState();
}

class _CuotasListScreenState extends ConsumerState<CuotasListScreen> {
  _Filtro _filtro = _Filtro.todas;

  // Filtros admin (null = todos/todas). Sólo se usan/mostran en adminMode.
  String? _cobradorId;
  String? _comunidadId;

  // Búsqueda de cliente (client-side sobre lo ya cargado, sin recrear el
  // stream en cada tecla). Normalizada a minúsculas.
  final _busquedaCtrl = TextEditingController();
  String _busqueda = '';

  // Streams de opciones de los dropdowns (sólo adminMode). Cacheados en
  // initState para no recrear suscripciones en cada build (anti-patrón
  // ps.db.watch inline). Cobradores activos del tenant + comunidades con
  // clientes activos.
  late final Stream<List<Map<String, dynamic>>> _cobradorOpcionesStream;
  late final Stream<List<Map<String, dynamic>>> _comunidadOpcionesStream;

  @override
  void initState() {
    super.initState();
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
    _busquedaCtrl.dispose();
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
              onChanged: (v) => setState(() => _cobradorId = v),
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
              onChanged: (v) => setState(() => _comunidadId = v),
            ),
          ),
        ],
      ),
    );
  }

  /// Buscador de cliente. Filtra client-side la lista ya cargada (no recrea el
  /// stream). Mismos criterios que el buscador del mapa: nombre/cédula/teléfono/
  /// código.
  Widget _buildBuscador() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        controller: _busquedaCtrl,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: 'Buscar cliente (nombre, cédula, teléfono o código)',
          suffixIcon: _busqueda.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Limpiar',
                  onPressed: () {
                    _busquedaCtrl.clear();
                    setState(() => _busqueda = '');
                  },
                ),
          border: const OutlineInputBorder(),
        ),
        onChanged: (v) => setState(() => _busqueda = v.trim().toLowerCase()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);

    // Safety-net del cold-start: '/' (= Cobros) es la landing del cobrador.
    // Si el router aún no resolvió el rol y un admin/admin_cobranza/super_admin
    // cayó acá, lo reencaminamos a /admin cuando llega su rol. Redundante con el
    // redirect del router, pero evita el flash de la pantalla del cobrador.
    //
    // En adminMode NO aplica: el admin entra a propósito a /admin/cobros y
    // debe quedarse acá (esta MISMA pantalla es su vista de monitoreo/cobro).
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

    // El filtro "Parciales" se muestra si el tenant permite pago parcial O si ya
    // hay cuotas parciales (históricas). Si queda oculto y estaba activo, se
    // vuelve a 'todas'.
    final mostrarParcial = settings.pagoParcialPermitido ||
        (ref.watch(hayCuotasParcialesProvider).valueOrNull ?? false);
    if (!mostrarParcial && _filtro == _Filtro.parciales) {
      _filtro = _Filtro.todas;
    }
    // "Ver todo" (sin límite de rango) es exclusivo del admin.
    if (!widget.adminMode && _filtro == _Filtro.verTodo) {
      _filtro = _Filtro.todas;
    }

    return Column(
      children: [
        // Filtros admin (cobrador / zona) — sólo en adminMode.
        if (widget.adminMode) _buildFiltrosAdmin(),
        _buildBuscador(),
        // Chips de estado.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              for (final f in _Filtro.values)
                if ((mostrarParcial || f != _Filtro.parciales) &&
                    (widget.adminMode || f != _Filtro.verTodo)) ...[
                  FilterChip(
                    label: Text(_label(f)),
                    selected: _filtro == f,
                    onSelected: (_) {
                      setState(() => _filtro = f);
                      // M12 (audit): en adminMode NO se marcan como vistas —
                      // el admin monitoreando borraba el badge del COBRADOR.
                      if (f == _Filtro.mora && !widget.adminMode) {
                        _marcarMoraComoVista();
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                ],
            ],
          ),
        ),
        Expanded(
          child: _CobrosList(
            adminMode: widget.adminMode,
            filtro: _filtro,
            diasGracia: diasGracia,
            diasVisibles: diasVisibles,
            cobradorId: widget.adminMode ? _cobradorId : null,
            comunidadId: widget.adminMode ? _comunidadId : null,
            busqueda: _busqueda,
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

// ─────────────────────────────────────────────────────────────────────────────
// Lista: una fila por contrato (cuota más antigua) + búsqueda client-side
// ─────────────────────────────────────────────────────────────────────────────

class _CobrosList extends StatefulWidget {
  const _CobrosList({
    required this.adminMode,
    required this.filtro,
    required this.diasGracia,
    required this.diasVisibles,
    required this.busqueda,
    this.cobradorId,
    this.comunidadId,
  });
  final bool adminMode;
  final _Filtro filtro;
  final int diasGracia;
  final int diasVisibles;
  final String busqueda;
  // Filtros admin (null = sin filtrar). En la vista del cobrador siempre null.
  final String? cobradorId;
  final String? comunidadId;

  @override
  State<_CobrosList> createState() => _CobrosListState();
}

class _CobrosListState extends State<_CobrosList> {
  late Stream<List<Map<String, dynamic>>> _cuotasStream;

  @override
  void initState() {
    super.initState();
    _cuotasStream = _buildStream();
  }

  @override
  void didUpdateWidget(_CobrosList old) {
    super.didUpdateWidget(old);
    // OJO: la búsqueda NO recrea el stream (se filtra client-side); sólo los
    // filtros que cambian la query SQL.
    if (old.filtro != widget.filtro ||
        old.diasGracia != widget.diasGracia ||
        old.diasVisibles != widget.diasVisibles ||
        old.cobradorId != widget.cobradorId ||
        old.comunidadId != widget.comunidadId) {
      setState(() => _cuotasStream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
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
      // Próximas: vencen DESPUÉS de hoy pero dentro del rango visible.
      _Filtro.proxima => (
          "AND cu.estado IN ('pendiente','parcial') "
              "AND date(cu.fecha_vencimiento) > date('now', '-6 hours') "
              "AND date(cu.fecha_vencimiento) <= date('now', '-6 hours', '+${widget.diasVisibles} days')",
          <Object?>[],
        ),
      // Ver todo (solo admin): TODO lo pendiente, SIN el límite de rango.
      _Filtro.verTodo => ("AND cu.estado IN ('pendiente','parcial')", <Object?>[]),
    };

    // Filtros admin (cobrador / zona). Se acumulan después de los params del
    // filtro de estado para preservar el orden posicional de los `?`.
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

    // Trae TODAS las cuotas que matchean; el agrupado por contrato (1 fila =
    // cuota más antigua) se hace client-side. Se seleccionan cédula/teléfono/
    // código para el buscador client-side.
    final sql = '''
      SELECT cu.id, cu.monto, cu.monto_pagado, cu.fecha_vencimiento,
             cu.periodo, cu.estado, cu.contrato_id,
             cu.descripcion, cu.tipo_cargo_manual,
             COALESCE(cu.cargos_neto, 0) AS cargos_neto,
             c.id AS cliente_id, c.nombre AS cliente_nombre,
             c.cedula AS cliente_cedula, c.telefono AS cliente_telefono,
             c.codigo AS cliente_codigo,
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
       ORDER BY cu.fecha_vencimiento ASC, c.nombre
    ''';

    return ps.db.watch(sql, parameters: allParams);
  }

  /// Matchea por nombre/cédula/teléfono/código (mismos criterios que el
  /// buscador del mapa). Para teléfono compara solo dígitos.
  bool _matchBusqueda(Map<String, dynamic> r, String q) {
    if (q.isEmpty) return true;
    final hay = [
      r['cliente_nombre'],
      r['cliente_cedula'],
      r['cliente_telefono'],
      r['cliente_codigo'],
    ].whereType<String>().join(' ').toLowerCase();
    if (hay.contains(q)) return true;
    final qDigits = q.replaceAll(RegExp(r'\D'), '');
    if (qDigits.isNotEmpty) {
      final telDigits =
          (r['cliente_telefono'] as String?)?.replaceAll(RegExp(r'\D'), '') ?? '';
      if (telDigits.contains(qDigits)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cuotasStream,
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

        // 1 fila por contrato = su cuota MÁS ANTIGUA pendiente. Las cuotas sin
        // contrato (cargos manuales sueltos) son cada una su propia fila.
        final masVieja = <String, Map<String, dynamic>>{};
        for (final r in rows) {
          if (!_matchBusqueda(r, widget.busqueda)) continue;
          final ctId = r['contrato_id'] as String?;
          final key = ctId ?? 'manual:${r['id']}';
          final actual = masVieja[key];
          if (actual == null ||
              (r['fecha_vencimiento'] as String)
                      .compareTo(actual['fecha_vencimiento'] as String) <
                  0) {
            masVieja[key] = r;
          }
        }
        final filas = masVieja.values.toList()
          ..sort((a, b) {
            final c = (a['fecha_vencimiento'] as String)
                .compareTo(b['fecha_vencimiento'] as String);
            if (c != 0) return c;
            return (a['cliente_nombre'] as String)
                .toLowerCase()
                .compareTo((b['cliente_nombre'] as String).toLowerCase());
          });

        if (filas.isEmpty) {
          return EmptyState(
            icon: Icons.check_circle_outline,
            titulo: widget.busqueda.isEmpty
                ? 'Nada por cobrar'
                : 'Sin resultados',
            descripcion: widget.busqueda.isEmpty
                ? 'No hay cuotas que coincidan con el filtro.'
                : 'Ningún cliente coincide con la búsqueda.',
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(8),
          itemCount: filas.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (context, i) {
            final row = filas[i];
            final cuotaId = row['id'] as String;
            final clienteId = row['cliente_id'] as String;
            return _CobroRow(
              row: row,
              diasGracia: widget.diasGracia,
              onTapCliente: () => context.push(widget.adminMode
                  ? '/admin/clientes/$clienteId'
                  : '/clientes/$clienteId'),
              onPagar: () => context.push('/cobro/$cuotaId'),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fila de cobro: cliente + cuota más antigua + botón Pagar
// ─────────────────────────────────────────────────────────────────────────────

class _CobroRow extends ConsumerWidget {
  const _CobroRow({
    required this.row,
    required this.diasGracia,
    required this.onTapCliente,
    required this.onPagar,
  });
  final Map<String, dynamic> row;
  final int diasGracia;
  final VoidCallback onTapCliente;
  final VoidCallback onPagar;

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
    // Saldo canónico (regla #10): incluye cargos_neto (reconexión suma,
    // descuento resta), clampeado a >= 0. Idéntico a cobro, recibo y mapa.
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

    final clienteNombre = row['cliente_nombre'] as String;
    final comunidad = row['comunidad'] as String?;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTapCliente,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              // Barra de color del estado.
              Container(
                width: 4,
                height: 40,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              // Cliente + cuota.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      clienteNombre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                    if (comunidad != null)
                      Text(
                        comunidad,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.outline, fontSize: 11),
                      ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('$mesLabel · ${Fmt.fechaCorta(vence)}',
                            style: TextStyle(
                                fontSize: 11, color: scheme.onSurface)),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(label,
                              style: TextStyle(
                                  color: color,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600)),
                        ),
                        if (esManual)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: scheme.tertiaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('Manual',
                                style: TextStyle(
                                    fontSize: 9,
                                    color: scheme.onTertiaryContainer)),
                          ),
                        if (esManual && row['tipo_cargo_manual'] != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _tipoLabel(row['tipo_cargo_manual'] as String),
                              style: TextStyle(
                                  fontSize: 9,
                                  color: scheme.onPrimaryContainer),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Saldo + botón Pagar.
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(Fmt.cordobas(saldo),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 4),
                  FilledButton(
                    onPressed: onPagar,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Pagar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
