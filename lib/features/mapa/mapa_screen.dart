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

class _MapaScreenState extends ConsumerState<MapaScreen> {
  // Cacheamos el stream de PowerSync en initState para evitar que cada
  // rebuild cree una nueva suscripción (anti-patrón ps.db.watch inline).
  // Se recrea cuando diasGracia cambia.
  late Stream<List<Map<String, dynamic>>> _clientesStream;
  int? _lastDiasGracia;

  Stream<List<Map<String, dynamic>>> _buildStream(int diasGracia) =>
      ps.db.watch(
        '''
        SELECT c.id, c.nombre, c.latitud, c.longitud,
               COUNT(cu.id) FILTER (WHERE cu.estado IN ('pendiente','parcial')) AS pendientes,
               COUNT(cu.id) FILTER (
                 WHERE cu.estado IN ('pendiente','parcial')
                   AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now')
               ) AS vencidas
          FROM clientes c
     LEFT JOIN cuotas cu ON cu.cliente_id = c.id
         WHERE c.activo = 1
           AND c.latitud IS NOT NULL
           AND c.longitud IS NOT NULL
         GROUP BY c.id, c.nombre, c.latitud, c.longitud
        ''',
        parameters: [diasGracia],
      );

  @override
  Widget build(BuildContext context) {
    final diasGracia = ref.watch(appSettingsProvider).diasGracia;

    // Recrea el stream si diasGracia cambió (o en el primer build).
    if (_lastDiasGracia != diasGracia) {
      _lastDiasGracia = diasGracia;
      _clientesStream = _buildStream(diasGracia);
    }

    return StreamBuilder(
      stream: _clientesStream,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
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

        // Centro: promedio de los puntos. Si hay uno, usa ese.
        final center = _calcularCentro(rows);

        return FlutterMap(
          options: MapOptions(
            initialCenter: center,
            initialZoom: 12.0,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.ispbilling.app',
            ),
            MarkerLayer(
              markers: rows.map((r) => _markerFor(context, r)).toList(),
            ),
            const _AttributionBanner(),
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
    final vencidas = (r['vencidas'] as int? ?? 0);
    final pendientes = (r['pendientes'] as int? ?? 0);
    final color = vencidas > 0
        ? scheme.error
        : pendientes > 0
            ? scheme.primary
            : scheme.tertiary;

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
            vencidas > 0
                ? Icons.warning
                : pendientes > 0
                    ? Icons.payments
                    : Icons.check,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }

  void _mostrarBottomSheet(BuildContext context, Map<String, dynamic> r, Color color) {
    final vencidas = (r['vencidas'] as int? ?? 0);
    final pendientes = (r['pendientes'] as int? ?? 0);
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
              Row(
                children: [
                  if (vencidas > 0)
                    Chip(
                      label: Text('$vencidas vencidas'),
                      avatar: Icon(Icons.warning,
                          size: 16, color: Theme.of(context).colorScheme.error),
                    )
                  else if (pendientes > 0)
                    Chip(label: Text('$pendientes pendientes'))
                  else
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
  const _AttributionBanner();
  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: EdgeInsets.all(4),
        child: Text(
          '© OpenStreetMap',
          style: TextStyle(fontSize: 10, color: Colors.black54),
        ),
      ),
    );
  }
}
