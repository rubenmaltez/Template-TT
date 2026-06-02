import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';

/// Mapa de clientes con flutter_map + OpenStreetMap (sin API key).
/// Marcador coloreado según estado de cobranza.
class MapaScreen extends ConsumerStatefulWidget {
  const MapaScreen({super.key});

  @override
  ConsumerState<MapaScreen> createState() => _MapaScreenState();
}

/// Estado de cobranza derivado de los counts de cuotas de un cliente.
/// Es la ÚNICA fuente de verdad de la derivación: la usan tanto el color/
/// ícono del marcador como el filtro de chips, para que los criterios
/// coincidan exactamente (precedencia: mora > gracia > pendiente > al día).
enum _EstadoCliente { mora, gracia, pendiente, alDia }

/// Opción seleccionada en la fila de chips de filtro sobre el mapa.
/// `todos` muestra todo; el resto matchea contra [_EstadoCliente].
enum _FiltroEstado { todos, mora, gracia, pendiente, alDia }

/// Deriva el estado de un cliente a partir de su row del stream, con la
/// MISMA precedencia que usa el color/ícono del marcador.
_EstadoCliente _estadoDe(Map<String, dynamic> r) {
  final vencidas = (r['vencidas'] as int? ?? 0);
  final enGracia = (r['en_gracia'] as int? ?? 0);
  final pendientes = (r['pendientes'] as int? ?? 0);
  if (vencidas > 0) return _EstadoCliente.mora;
  if (enGracia > 0) return _EstadoCliente.gracia;
  if (pendientes > 0) return _EstadoCliente.pendiente;
  return _EstadoCliente.alDia;
}

class _MapaScreenState extends ConsumerState<MapaScreen> {
  // Cacheamos el stream de PowerSync en initState para evitar que cada
  // rebuild cree una nueva suscripción (anti-patrón ps.db.watch inline).
  // Se recrea cuando diasGracia cambia.
  late Stream<List<Map<String, dynamic>>> _clientesStream;
  int? _lastDiasGracia;

  // Estado del filtro de chips (default: todos los marcadores).
  _FiltroEstado _filtro = _FiltroEstado.todos;
  // Filtros SOLO para admin (el cobrador ve solo sus propios clientes, no
  // tiene sentido filtrar por cobrador/zona). null = todos / todas.
  String? _cobradorId;
  String? _comunidadId;
  // Toggle de capa: false = calle (OSM), true = satélite (Esri).
  bool _satelite = false;

  Stream<List<Map<String, dynamic>>> _buildStream(int diasGracia) =>
      ps.db.watch(
        '''
        SELECT c.id, c.nombre, c.latitud, c.longitud,
               c.cobrador_id, c.comunidad_id,
               co.nombre AS comunidad,
               cob.nombre AS cobrador_nombre,
               COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial') THEN 1 ELSE 0 END), 0) AS pendientes,
               COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                   AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now')
                 THEN 1 ELSE 0 END), 0) AS vencidas,
               COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                   AND date(cu.fecha_vencimiento) < date('now')
                   AND date(cu.fecha_vencimiento, '+' || ? || ' days') >= date('now')
                 THEN 1 ELSE 0 END), 0) AS en_gracia,
               (SELECT COUNT(*) FROM contratos ct
                 WHERE ct.cliente_id = c.id
                   AND COALESCE(ct.estado, 'activo') = 'activo') AS contratos_activos
          FROM clientes c
     LEFT JOIN cuotas cu ON cu.cliente_id = c.id
     LEFT JOIN comunidades co ON co.id = c.comunidad_id
     LEFT JOIN cobradores cob ON cob.id = c.cobrador_id
         WHERE c.activo = 1
           AND c.latitud IS NOT NULL
           AND c.longitud IS NOT NULL
         GROUP BY c.id, c.nombre, c.latitud, c.longitud,
                  c.cobrador_id, c.comunidad_id, co.nombre, cob.nombre
        ''',
        // diasGracia x2: vencidas + en_gracia, en orden de aparición.
        parameters: [diasGracia, diasGracia],
      );

  @override
  void initState() {
    super.initState();
    // Inicialización diferida: diasGracia viene de Riverpod, no está
    // disponible en initState. Se setea en el primer build via el
    // listener de abajo.
  }

  @override
  Widget build(BuildContext context) {
    final diasGracia = ref.watch(appSettingsProvider).diasGracia;

    // Vista admin: el cobrador puro ve solo sus clientes → no necesita los
    // filtros por cobrador/zona. Los mostramos solo si NO es cobrador.
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esAdminView = cobrador != null && !cobrador.esCobrador;

    // Recrea el stream si diasGracia cambió (o en el primer build).
    // Patrón setState explícito para que StreamBuilder reciba la nueva
    // referencia de stream de forma predecible (audit HIGH fix).
    if (_lastDiasGracia != diasGracia) {
      _lastDiasGracia = diasGracia;
      // No usamos setState acá porque ya estamos en build y Flutter
      // no permite setState durante build. La asignación directa es
      // segura porque StreamBuilder recibe el nuevo stream reference
      // en este mismo frame de build. Este es el patrón correcto para
      // providers de Riverpod que cambian entre builds — no hay
      // didUpdateWidget para Riverpod, solo ref.watch en build.
      _clientesStream = _buildStream(diasGracia);
    }

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _clientesStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.location_off_outlined,
            titulo: 'Sin ubicaciones',
            descripcion:
                'Ningún cliente tiene coordenadas GPS guardadas todavía.',
          );
        }

        // Centro: promedio de TODOS los puntos (no del subconjunto filtrado),
        // para que el encuadre inicial sea estable al cambiar de filtro.
        final center = _calcularCentro(rows);

        // Opciones de los dropdowns (solo admin): cobradores y zonas
        // distintas presentes en las filas cargadas, sin queries extra.
        // null = "Todos"/"Todas".
        final cobradorOpciones = esAdminView ? _opcionesDistinct(
          rows,
          idKey: 'cobrador_id',
          labelKey: 'cobrador_nombre',
        ) : const <({String id, String label})>[];
        final comunidadOpciones = esAdminView ? _opcionesDistinct(
          rows,
          idKey: 'comunidad_id',
          labelKey: 'comunidad',
        ) : const <({String id, String label})>[];

        // El cobrador puro no ve los dropdowns; sus filtros quedan null para
        // que nunca recorten su set de clientes.
        final cobradorId = esAdminView ? _cobradorId : null;
        final comunidadId = esAdminView ? _comunidadId : null;

        // Filtra qué clientes se muestran combinando las 3 condiciones:
        // estado (chips, _estadoDe) + cobrador + zona (dropdowns admin).
        // _estadoDe se reusa para que filtro y color del marcador no diverjan.
        final visibles = rows.where((r) {
          final pasaEstado = _filtro == _FiltroEstado.todos ||
              switch (_filtro) {
                _FiltroEstado.todos => true,
                _FiltroEstado.mora => _estadoDe(r) == _EstadoCliente.mora,
                _FiltroEstado.gracia => _estadoDe(r) == _EstadoCliente.gracia,
                _FiltroEstado.pendiente =>
                  _estadoDe(r) == _EstadoCliente.pendiente,
                _FiltroEstado.alDia => _estadoDe(r) == _EstadoCliente.alDia,
              };
          final pasaCobrador =
              cobradorId == null || r['cobrador_id'] == cobradorId;
          final pasaComunidad =
              comunidadId == null || r['comunidad_id'] == comunidadId;
          return pasaEstado && pasaCobrador && pasaComunidad;
        }).toList();

        return Stack(
          children: [
            FlutterMap(
              options: MapOptions(
                initialCenter: center,
                initialZoom: 12.0,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: _satelite
                      ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                      : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.ispbilling.app',
                ),
                MarkerLayer(
                  markers:
                      visibles.map((r) => _markerFor(context, r)).toList(),
                ),
                _AttributionBanner(satelite: _satelite),
              ],
            ),
            // Fila de chips de filtro por estado (overlay arriba) +, solo
            // para admin, una segunda fila con dropdowns de cobrador y zona.
            Positioned(
              top: 8,
              left: 8,
              right: 56, // deja lugar para el botón de capa
              child: SafeArea(
                bottom: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _FiltroChips(
                      seleccionado: _filtro,
                      onChanged: (f) => setState(() => _filtro = f),
                    ),
                    if (esAdminView) ...[
                      const SizedBox(height: 6),
                      _FiltrosAdmin(
                        cobradorId: cobradorId,
                        comunidadId: comunidadId,
                        cobradorOpciones: cobradorOpciones,
                        comunidadOpciones: comunidadOpciones,
                        onCobradorChanged: (v) =>
                            setState(() => _cobradorId = v),
                        onComunidadChanged: (v) =>
                            setState(() => _comunidadId = v),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Botón flotante para alternar calle ↔ satélite.
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                bottom: false,
                child: FloatingActionButton.small(
                  heroTag: 'mapa_capa_toggle',
                  tooltip: _satelite ? 'Ver calles' : 'Ver satélite',
                  onPressed: () => setState(() => _satelite = !_satelite),
                  child: Icon(_satelite ? Icons.map : Icons.layers),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  LatLng _calcularCentro(List<Map<String, dynamic>> rows) {
    double sumLat = 0, sumLng = 0;
    for (final r in rows) {
      sumLat += (r['latitud'] as num).toDouble();
      sumLng += (r['longitud'] as num).toDouble();
    }
    return LatLng(sumLat / rows.length, sumLng / rows.length);
  }

  /// Deriva las opciones de un dropdown desde las filas ya cargadas: pares
  /// (id, label) distintos, ignorando filas con id null, ordenados por label.
  /// Sin queries extra — todo sale del stream del mapa.
  List<({String id, String label})> _opcionesDistinct(
    List<Map<String, dynamic>> rows, {
    required String idKey,
    required String labelKey,
  }) {
    final byId = <String, String>{};
    for (final r in rows) {
      final id = r[idKey] as String?;
      if (id == null) continue;
      byId[id] = (r[labelKey] as String?) ?? id;
    }
    final opciones = byId.entries
        .map((e) => (id: e.key, label: e.value))
        .toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return opciones;
  }

  Marker _markerFor(BuildContext context, Map<String, dynamic> r) {
    final scheme = Theme.of(context).colorScheme;
    // Reusa la derivación de estado compartida con el filtro de chips, así
    // color/ícono y filtro nunca divergen.
    final estado = _estadoDe(r);
    // En gracia → ámbar (entre el rojo de vencida y el normal de pendiente).
    final Color color;
    final IconData icono;
    switch (estado) {
      case _EstadoCliente.mora:
        color = scheme.error;
        icono = Icons.warning;
        break;
      case _EstadoCliente.gracia:
        color = const Color(0xFFB45309);
        icono = Icons.hourglass_bottom;
        break;
      case _EstadoCliente.pendiente:
        color = scheme.primary;
        icono = Icons.payments;
        break;
      case _EstadoCliente.alDia:
        color = scheme.tertiary;
        icono = Icons.check;
        break;
    }

    return Marker(
      point: LatLng(
        (r['latitud'] as num).toDouble(),
        (r['longitud'] as num).toDouble(),
      ),
      width: 40,
      height: 40,
      child: GestureDetector(
        onTap: () => _mostrarBottomSheet(context, r, color),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
            ],
          ),
          child: Icon(
            icono,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }

  void _mostrarBottomSheet(BuildContext context, Map<String, dynamic> r, Color color) {
    final vencidas = (r['vencidas'] as int? ?? 0);
    final enGracia = (r['en_gracia'] as int? ?? 0);
    final pendientes = (r['pendientes'] as int? ?? 0);
    final contratos = (r['contratos_activos'] as int? ?? 0);
    const ambar = Color(0xFFB45309);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r['nombre'] as String,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (contratos >= 2)
                    Chip(
                      label: Text('$contratos contratos'),
                      avatar: Icon(Icons.description_outlined,
                          size: 16, color: Theme.of(context).colorScheme.primary),
                    ),
                  if (vencidas > 0)
                    Chip(
                      label: Text('$vencidas vencidas'),
                      avatar: Icon(Icons.warning,
                          size: 16, color: Theme.of(context).colorScheme.error),
                    ),
                  if (enGracia > 0)
                    Chip(
                      label: Text('$enGracia en gracia'),
                      avatar: const Icon(Icons.hourglass_bottom,
                          size: 16, color: ambar),
                    ),
                  if (vencidas == 0 && enGracia == 0 && pendientes > 0)
                    Chip(label: Text('$pendientes pendientes')),
                  if (vencidas == 0 && enGracia == 0 && pendientes == 0)
                    const Chip(label: Text('Al día'),
                        avatar: Icon(Icons.check, size: 16)),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.person),
                label: const Text('Ver cliente'),
                onPressed: () {
                  Navigator.pop(context);
                  context.push('/clientes/${r['id']}');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttributionBanner extends StatelessWidget {
  const _AttributionBanner({required this.satelite});

  /// Cuando true, el tile es Esri World Imagery → atribución de Esri.
  final bool satelite;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white70,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: Text(
              satelite
                  ? '© Esri, Maxar, Earthstar Geographics'
                  : '© OpenStreetMap',
              style: const TextStyle(fontSize: 10, color: Colors.black87),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fila de chips de filtro por estado de cobranza, sobre el mapa.
/// Los criterios coinciden con [_estadoDe] (misma derivación que el color).
class _FiltroChips extends StatelessWidget {
  const _FiltroChips({required this.seleccionado, required this.onChanged});

  final _FiltroEstado seleccionado;
  final ValueChanged<_FiltroEstado> onChanged;

  static const _opciones = <(_FiltroEstado, String)>[
    (_FiltroEstado.todos, 'Todos'),
    (_FiltroEstado.mora, 'En mora'),
    (_FiltroEstado.gracia, 'En gracia'),
    (_FiltroEstado.alDia, 'Al día'),
    (_FiltroEstado.pendiente, 'Pendientes'),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final (estado, label) in _opciones)
          ChoiceChip(
            label: Text(label),
            selected: seleccionado == estado,
            visualDensity: VisualDensity.compact,
            // Fondo opaco para que se lea sobre el tile del mapa.
            backgroundColor: Theme.of(context).colorScheme.surface,
            onSelected: (_) => onChanged(estado),
          ),
      ],
    );
  }
}

/// Segunda fila de filtros del overlay, SOLO para la vista admin: dropdowns
/// de cobrador y zona (comunidad). Las opciones se derivan de las filas del
/// mapa; null = "Todos"/"Todas". El cobrador puro no ve esta fila.
class _FiltrosAdmin extends StatelessWidget {
  const _FiltrosAdmin({
    required this.cobradorId,
    required this.comunidadId,
    required this.cobradorOpciones,
    required this.comunidadOpciones,
    required this.onCobradorChanged,
    required this.onComunidadChanged,
  });

  final String? cobradorId;
  final String? comunidadId;
  final List<({String id, String label})> cobradorOpciones;
  final List<({String id, String label})> comunidadOpciones;
  final ValueChanged<String?> onCobradorChanged;
  final ValueChanged<String?> onComunidadChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        _DropdownFiltro(
          icon: Icons.person_outline,
          hint: 'Cobrador',
          todosLabel: 'Todos',
          value: cobradorId,
          opciones: cobradorOpciones,
          onChanged: onCobradorChanged,
        ),
        _DropdownFiltro(
          icon: Icons.place_outlined,
          hint: 'Zona',
          todosLabel: 'Todas',
          value: comunidadId,
          opciones: comunidadOpciones,
          onChanged: onComunidadChanged,
        ),
      ],
    );
  }
}

/// Chip desplegable: mismo look redondeado que los ChoiceChip de estado, con
/// ícono + "Etiqueta: selección ▾". Abre un menú con "Todos/Todas" (value null)
/// + las opciones. Se resalta (primaryContainer) cuando hay un filtro activo.
class _DropdownFiltro extends StatelessWidget {
  const _DropdownFiltro({
    required this.icon,
    required this.hint,
    required this.todosLabel,
    required this.value,
    required this.opciones,
    required this.onChanged,
  });

  final IconData icon;
  final String hint;
  final String todosLabel;
  final String? value;
  final List<({String id, String label})> opciones;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Si el value seleccionado ya no está entre las opciones (ej. el cliente
    // filtrado dejó de tener filas), caemos a null.
    final valido =
        value != null && opciones.any((o) => o.id == value) ? value : null;
    final activo = valido != null;
    final seleccion =
        activo ? opciones.firstWhere((o) => o.id == valido).label : todosLabel;

    return PopupMenuButton<String?>(
      tooltip: hint,
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (context) => [
        PopupMenuItem<String?>(
          value: null,
          child: _MenuRow(label: todosLabel, seleccionado: !activo),
        ),
        if (opciones.isNotEmpty) const PopupMenuDivider(),
        for (final o in opciones)
          PopupMenuItem<String?>(
            value: o.id,
            child: _MenuRow(label: o.label, seleccionado: o.id == valido),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
        decoration: BoxDecoration(
          color: activo ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: activo ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: activo
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              '$hint: $seleccion',
              style: TextStyle(
                fontSize: 13,
                fontWeight: activo ? FontWeight.w600 : FontWeight.normal,
                color: activo ? scheme.onPrimaryContainer : scheme.onSurface,
              ),
            ),
            Icon(Icons.arrow_drop_down,
                size: 18,
                color: activo
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// Ítem del menú del chip desplegable: check a la izquierda si está elegido.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.label, required this.seleccionado});

  final String label;
  final bool seleccionado;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 18,
          child: seleccionado
              ? Icon(Icons.check, size: 18, color: scheme.primary)
              : null,
        ),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }
}
