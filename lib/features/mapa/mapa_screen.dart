import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

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
  // Toggle de capa: false = calle (OSM), true = satélite (Esri).
  bool _satelite = false;

  Stream<List<Map<String, dynamic>>> _buildStream(int diasGracia) =>
      ps.db.watch(
        '''
        SELECT c.id, c.nombre, c.latitud, c.longitud,
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
         WHERE c.activo = 1
           AND c.latitud IS NOT NULL
           AND c.longitud IS NOT NULL
         GROUP BY c.id, c.nombre, c.latitud, c.longitud
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

        // Filtra qué clientes se muestran según el chip seleccionado.
        // Reusa _estadoDe (misma derivación que el color del marcador).
        final visibles = _filtro == _FiltroEstado.todos
            ? rows
            : rows.where((r) {
                switch (_filtro) {
                  case _FiltroEstado.todos:
                    return true;
                  case _FiltroEstado.mora:
                    return _estadoDe(r) == _EstadoCliente.mora;
                  case _FiltroEstado.gracia:
                    return _estadoDe(r) == _EstadoCliente.gracia;
                  case _FiltroEstado.pendiente:
                    return _estadoDe(r) == _EstadoCliente.pendiente;
                  case _FiltroEstado.alDia:
                    return _estadoDe(r) == _EstadoCliente.alDia;
                }
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
            // Fila de chips de filtro por estado (overlay arriba).
            Positioned(
              top: 8,
              left: 8,
              right: 56, // deja lugar para el botón de capa
              child: SafeArea(
                bottom: false,
                child: _FiltroChips(
                  seleccionado: _filtro,
                  onChanged: (f) => setState(() => _filtro = f),
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
