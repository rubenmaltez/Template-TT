import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../data/services/map_tile_cache.dart';

/// Pantalla full-screen para elegir coordenadas tocando el mapa. Compartida por
/// el form de cliente y el de nodo de red. Devuelve el `LatLng` elegido vía
/// `Navigator.pop`, o null si se cancela. Usa el caché de tiles offline.
class MapaPickerScreen extends StatefulWidget {
  const MapaPickerScreen({super.key, required this.inicial});
  final LatLng inicial;

  @override
  State<MapaPickerScreen> createState() => _MapaPickerScreenState();
}

class _MapaPickerScreenState extends State<MapaPickerScreen> {
  late LatLng _punto;

  @override
  void initState() {
    super.initState();
    _punto = widget.inicial;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Seleccionar ubicación'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: () => Navigator.pop(context, _punto),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              options: MapOptions(
                initialCenter: _punto,
                initialZoom: 13,
                onTap: (_, p) => setState(() => _punto = p),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.ispbilling.app',
                  tileProvider: MapTileCache.instance.tileProvider(),
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _punto,
                      width: 40,
                      height: 40,
                      child: Icon(Icons.location_on,
                          color: Theme.of(context).colorScheme.error, size: 40),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Lat: ${_punto.latitude.toStringAsFixed(6)}, '
              'Lng: ${_punto.longitude.toStringAsFixed(6)}',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
