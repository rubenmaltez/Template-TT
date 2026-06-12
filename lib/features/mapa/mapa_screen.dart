import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/services/map_tile_cache.dart';
import '../../data/utils/cuota_estado_visual.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/dropdown_filtro.dart';
import '../shared/widgets/empty_state.dart';
import '../../data/utils/errores.dart';

/// Mapa de clientes con flutter_map + OpenStreetMap (sin API key).
/// Marcador coloreado según estado de cobranza.
class MapaScreen extends ConsumerStatefulWidget {
  const MapaScreen({super.key});

  @override
  ConsumerState<MapaScreen> createState() => _MapaScreenState();
}

/// Opción seleccionada en la fila de chips de filtro sobre el mapa.
/// `pendientes` = superconjunto cobrable en rango (mora+gracia+hoy+próxima);
/// `verTodo` (solo admin) suma fuera-de-rango y sin-deuda; el resto matchea
/// contra un único [CuotaEstadoVisual].
enum _FiltroEstado { pendientes, mora, gracia, hoy, proxima, verTodo }

/// Deriva el estado VISUAL de un cliente a partir de los counts de cuotas de su
/// row, con la precedencia mora > gracia > hoy > próxima > fuera de rango > sin
/// deuda. La usan el color/ícono del marcador y el filtro de chips, para que
/// nunca diverjan.
CuotaEstadoVisual _estadoDe(Map<String, dynamic> r) {
  final vencidas = (r['vencidas'] as int? ?? 0);
  final enGracia = (r['en_gracia'] as int? ?? 0);
  final venceHoy = (r['vence_hoy'] as int? ?? 0);
  final proximas = (r['proximas'] as int? ?? 0);
  final fueraRango = (r['fuera_rango'] as int? ?? 0);
  if (vencidas > 0) return CuotaEstadoVisual.mora;
  if (enGracia > 0) return CuotaEstadoVisual.gracia;
  if (venceHoy > 0) return CuotaEstadoVisual.hoy;
  if (proximas > 0) return CuotaEstadoVisual.proxima;
  if (fueraRango > 0) return CuotaEstadoVisual.fueraDeRango;
  return CuotaEstadoVisual.sinDeuda;
}

class _MapaScreenState extends ConsumerState<MapaScreen> {
  // Cacheamos el stream de PowerSync en initState para evitar que cada
  // rebuild cree una nueva suscripción (anti-patrón ps.db.watch inline).
  // Se recrea cuando diasGracia cambia.
  late Stream<List<Map<String, dynamic>>> _clientesStream;
  int? _lastDiasGracia;
  int? _lastDiasVisibles;

  // Estado del filtro de chips (default: lo cobrable dentro del rango).
  _FiltroEstado _filtro = _FiltroEstado.pendientes;
  // Filtros SOLO para admin (el cobrador ve solo sus propios clientes, no
  // tiene sentido filtrar por cobrador/zona). null = todos / todas.
  String? _cobradorId;
  String? _comunidadId;
  String? _nodoId;
  // Toggle de capa: false = calle (OSM), true = satélite (Esri).
  bool _satelite = false;
  // Cliente enfocado por la búsqueda: cuando != null, el mapa muestra SOLO su
  // pin (ignora los demás filtros) y centra/zoom en él. La X lo limpia.
  String? _clienteSeleccionadoId;
  final _mapController = MapController();
  Position? _currentPosition;
  StreamSubscription<Position>? _positionSubscription;

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _initLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) return;

      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen(
        (position) {
          if (mounted) {
            setState(() => _currentPosition = position);
          }
        },
        onError: (e) {
          if (kDebugMode) debugPrint('Error en stream de ubicación: $e');
        },
      );

      final lastPos = await Geolocator.getLastKnownPosition();
      if (lastPos != null && mounted && _currentPosition == null) {
        setState(() => _currentPosition = lastPos);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error _initLocation: $e');
    }
  }

  Future<void> _centrarEnUbicacion() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('El servicio de GPS está desactivado.')),
          );
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Permiso de ubicación denegado.')),
            );
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permiso de ubicación denegado permanentemente.')),
          );
        }
        return;
      }

      if (_positionSubscription == null) {
        _initLocation();
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (mounted) {
        setState(() => _currentPosition = pos);
        _mapController.move(LatLng(pos.latitude, pos.longitude), 16.0);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo obtener la ubicación: ${mensajeErrorHumano(e)}')),
        );
      }
    }
  }

  void _seleccionarCliente(Map<String, dynamic> r) {
    setState(() => _clienteSeleccionadoId = r['id'] as String);
    final lat = (r['latitud'] as num).toDouble();
    final lng = (r['longitud'] as num).toDouble();
    // Mover tras el frame para asegurar que el MapController esté montado.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mapController.move(LatLng(lat, lng), 16.0);
    });
  }

  void _limpiarSeleccion() => setState(() => _clienteSeleccionadoId = null);

  Future<void> _abrirBuscador(List<Map<String, dynamic>> rows) async {
    final r = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _BuscadorClientes(rows: rows),
    );
    if (r != null) _seleccionarCliente(r);
  }

  Stream<List<Map<String, dynamic>>> _buildStream(
          int diasGracia, int diasVisibles) =>
      ps.db.watch(
        '''
        SELECT c.id, c.nombre, c.latitud, c.longitud,
               c.cobrador_id, c.comunidad_id, c.puerto_id,
               c.cedula, c.telefono, c.codigo,
               c.direccion, c.direccion_referencia,
               (SELECT GROUP_CONCAT(ct.codigo, ' ')
                  FROM contratos ct WHERE ct.cliente_id = c.id) AS contrato_codigos,
               co.nombre AS comunidad,
               n.id AS nodo_id, n.nombre AS nodo,
               cob.nombre AS cobrador_nombre,
               COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                   AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now', '-6 hours')
                 THEN 1 ELSE 0 END), 0) AS vencidas,
               COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                   AND date(cu.fecha_vencimiento) < date('now', '-6 hours')
                   AND date(cu.fecha_vencimiento, '+' || ? || ' days') >= date('now', '-6 hours')
                 THEN 1 ELSE 0 END), 0) AS en_gracia,
               COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                   AND date(cu.fecha_vencimiento) = date('now', '-6 hours')
                 THEN 1 ELSE 0 END), 0) AS vence_hoy,
               COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                   AND date(cu.fecha_vencimiento) > date('now', '-6 hours')
                   AND date(cu.fecha_vencimiento) <= date('now', '-6 hours', '+' || ? || ' days')
                 THEN 1 ELSE 0 END), 0) AS proximas,
               COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                   AND date(cu.fecha_vencimiento) > date('now', '-6 hours', '+' || ? || ' days')
                 THEN 1 ELSE 0 END), 0) AS fuera_rango,
               (SELECT COUNT(*) FROM contratos ct
                 WHERE ct.cliente_id = c.id
                   AND COALESCE(ct.estado, 'activo') = 'activo') AS contratos_activos
          FROM clientes c
     LEFT JOIN cuotas cu ON cu.cliente_id = c.id
     LEFT JOIN comunidades co ON co.id = c.comunidad_id
     LEFT JOIN red_puertos p ON p.id = c.puerto_id
     LEFT JOIN red_hubs h ON h.id = p.hub_id
     LEFT JOIN red_nodos n ON n.id = h.nodo_id
     LEFT JOIN cobradores cob ON cob.id = c.cobrador_id
         WHERE c.activo = 1
           AND c.latitud IS NOT NULL
           AND c.longitud IS NOT NULL
         GROUP BY c.id, c.nombre, c.latitud, c.longitud,
                  c.cobrador_id, c.comunidad_id, c.puerto_id,
                  c.cedula, c.telefono, c.codigo,
                  c.direccion, c.direccion_referencia, co.nombre,
                  n.id, n.nombre, cob.nombre
        ''',
        // Orden de los ?: diasGracia (vencidas), diasGracia (en_gracia),
        // diasVisibles (proximas), diasVisibles (fuera_rango).
        parameters: [diasGracia, diasGracia, diasVisibles, diasVisibles],
      );

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final diasGracia = settings.diasGracia;
    final diasVisibles = settings.diasCuotasVisibles;
    final colores = settings.coloresEstados;

    // Vista admin: los roles de campo (cobrador, técnico) ven solo SUS clientes
    // → no necesitan los filtros por cobrador/zona. Los mostramos solo para los
    // roles con vista de todo el tenant (admin/admin_cobranza/super_admin).
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esAdminView =
        cobrador != null && !cobrador.esCobrador && !cobrador.esTecnico;

    // "Ver todo" (fuera de rango + sin deuda) es exclusivo del admin. Si un rol
    // de campo quedara con ese filtro (no debería: el chip no se le muestra), lo
    // devolvemos al default cobrable.
    if (!esAdminView && _filtro == _FiltroEstado.verTodo) {
      _filtro = _FiltroEstado.pendientes;
    }

    // Recrea el stream si diasGracia o diasVisibles cambiaron (o primer build).
    // Asignación directa (no setState): ya estamos en build y StreamBuilder
    // recibe la nueva referencia en este mismo frame (audit HIGH fix). Es el
    // patrón correcto para providers de Riverpod que cambian entre builds.
    if (_lastDiasGracia != diasGracia || _lastDiasVisibles != diasVisibles) {
      _lastDiasGracia = diasGracia;
      _lastDiasVisibles = diasVisibles;
      _clientesStream = _buildStream(diasGracia, diasVisibles);
    }

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _clientesStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text(mensajeErrorHumano(snap.error!)));
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
        final nodoOpciones = esAdminView ? _opcionesDistinct(
          rows,
          idKey: 'nodo_id',
          labelKey: 'nodo',
        ) : const <({String id, String label})>[];

        // El cobrador puro no ve los dropdowns; sus filtros quedan null para
        // que nunca recorten su set de clientes.
        final cobradorId = esAdminView ? _cobradorId : null;
        final comunidadId = esAdminView ? _comunidadId : null;
        final nodoId = esAdminView ? _nodoId : null;

        // Si hay un cliente buscado, el mapa muestra SOLO su pin (ignora los
        // chips y dropdowns: el usuario lo eligió explícitamente). Si ese id
        // ya no está en el set (se filtró/sincronizó fuera), cae a "todos".
        final seleccionado = _clienteSeleccionadoId == null
            ? null
            : rows.cast<Map<String, dynamic>?>().firstWhere(
                  (r) => r!['id'] == _clienteSeleccionadoId,
                  orElse: () => null,
                );

        // Filtra qué clientes se muestran combinando las 3 condiciones:
        // estado (chips, _estadoDe) + cobrador + zona (dropdowns admin).
        // _estadoDe se reusa para que filtro y color del marcador no diverjan.
        final visibles = seleccionado != null
            ? [seleccionado]
            : rows.where((r) {
                final estado = _estadoDe(r);
                final pasaEstado = switch (_filtro) {
                  // Default: todo lo cobrable dentro del rango. Excluye fuera de
                  // rango y sin deuda (el cobrador nunca los ve).
                  _FiltroEstado.pendientes =>
                    estado == CuotaEstadoVisual.mora ||
                        estado == CuotaEstadoVisual.gracia ||
                        estado == CuotaEstadoVisual.hoy ||
                        estado == CuotaEstadoVisual.proxima,
                  _FiltroEstado.mora => estado == CuotaEstadoVisual.mora,
                  _FiltroEstado.gracia => estado == CuotaEstadoVisual.gracia,
                  _FiltroEstado.hoy => estado == CuotaEstadoVisual.hoy,
                  _FiltroEstado.proxima => estado == CuotaEstadoVisual.proxima,
                  // Solo admin: incluye fuera de rango y sin deuda.
                  _FiltroEstado.verTodo => true,
                };
                final pasaCobrador =
                    cobradorId == null || r['cobrador_id'] == cobradorId;
                final pasaComunidad =
                    comunidadId == null || r['comunidad_id'] == comunidadId;
                final pasaNodo = nodoId == null || r['nodo_id'] == nodoId;
                return pasaEstado && pasaCobrador && pasaComunidad && pasaNodo;
              }).toList();

        return Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
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
                  // Caché en disco (Android/Windows): los tiles que el usuario
                  // navega CON señal quedan offline. Ambas capas comparten el
                  // store (las URLs distintas no se pisan). En web cae a red.
                  tileProvider: MapTileCache.instance.tileProvider(),
                ),
                MarkerLayer(
                  markers: [
                    ...visibles.map((r) => _markerFor(context, r, colores)),
                    if (_currentPosition != null)
                      Marker(
                        point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                        width: 40,
                        height: 40,
                        child: const _UbicacionActualMarker(),
                      ),
                  ],
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
                // Cliente buscado → banner con su nombre + X para volver a
                // todos. Si no, los filtros normales (chips + dropdowns admin).
                child: seleccionado != null
                    ? _BannerSeleccion(
                        nombre: seleccionado['nombre'] as String,
                        onClear: _limpiarSeleccion,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FiltroChips(
                            seleccionado: _filtro,
                            colores: colores,
                            esAdmin: esAdminView,
                            onChanged: (f) => setState(() => _filtro = f),
                          ),
                          if (esAdminView) ...[
                            const SizedBox(height: 6),
                            _FiltrosAdmin(
                              cobradorId: cobradorId,
                              comunidadId: comunidadId,
                              nodoId: nodoId,
                              cobradorOpciones: cobradorOpciones,
                              comunidadOpciones: comunidadOpciones,
                              nodoOpciones: nodoOpciones,
                              onCobradorChanged: (v) =>
                                  setState(() => _cobradorId = v),
                              onComunidadChanged: (v) =>
                                  setState(() => _comunidadId = v),
                              onNodoChanged: (v) =>
                                  setState(() => _nodoId = v),
                            ),
                          ],
                        ],
                      ),
              ),
            ),
            // Botón de búsqueda de cliente (centra/zoom en su pin). Oculto
            // mientras hay uno enfocado — el X del banner vuelve a todos.
            Positioned(
              bottom: 16,
              right: 16,
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton.small(
                      heroTag: 'mapa_mi_ubicacion',
                      tooltip: 'Centrar en mi ubicación',
                      onPressed: _centrarEnUbicacion,
                      child: const Icon(Icons.my_location),
                    ),
                    if (seleccionado == null) ...[
                      const SizedBox(height: 12),
                      FloatingActionButton(
                        heroTag: 'mapa_buscar',
                        tooltip: 'Buscar cliente',
                        onPressed: () => _abrirBuscador(rows),
                        child: const Icon(Icons.search),
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

  Marker _markerFor(
      BuildContext context, Map<String, dynamic> r, ColoresEstados colores) {
    // Reusa la derivación de estado compartida con el filtro de chips, así
    // color/ícono y filtro nunca divergen. El color sale de la paleta
    // configurable del tenant (settings → cobranza.colores_estados).
    final estado = _estadoDe(r);
    final color = colores.color(estado);
    final icono = _iconoDe(estado);

    return Marker(
      point: LatLng(
        (r['latitud'] as num).toDouble(),
        (r['longitud'] as num).toDouble(),
      ),
      width: 40,
      height: 40,
      child: GestureDetector(
        onTap: () => _mostrarBottomSheet(context, r),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
            ],
          ),
          child: Icon(icono, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  IconData _iconoDe(CuotaEstadoVisual estado) => switch (estado) {
        CuotaEstadoVisual.mora => Icons.warning,
        CuotaEstadoVisual.gracia => Icons.hourglass_bottom,
        CuotaEstadoVisual.hoy => Icons.payments,
        CuotaEstadoVisual.proxima => Icons.schedule,
        CuotaEstadoVisual.fueraDeRango => Icons.more_time,
        CuotaEstadoVisual.sinDeuda => Icons.check,
      };

  void _mostrarBottomSheet(BuildContext context, Map<String, dynamic> r) {
    // El técnico no ve cobranza ni "Pagar"/"Ver cliente" (su SQLite no tiene
    // cuotas y /clientes/:id lo rebota) — sí ve contacto + ruta. B8 del audit.
    final esTecnico =
        ref.read(cobradorActualProvider).valueOrNull?.esTecnico ?? false;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ClientePinSheet(row: r, esTecnico: esTecnico),
    );
  }
}

/// Cuota pendiente más vieja de un contrato (para el botón "Pagar" del mapa).
typedef _ContratoCuota = ({
  String contratoId,
  String? planNombre,
  int? diaPago,
  String cuotaId,
  String periodo,
  double saldo,
});

/// Popup del pin de cliente en el mapa: foto de la casa + contacto + acciones
/// (llamar, ruta, ver cliente, pagar la cuota más vieja). Acceso rápido de campo.
class _ClientePinSheet extends ConsumerStatefulWidget {
  const _ClientePinSheet({required this.row, required this.esTecnico});
  final Map<String, dynamic> row;
  final bool esTecnico;

  @override
  ConsumerState<_ClientePinSheet> createState() => _ClientePinSheetState();
}

class _ClientePinSheetState extends ConsumerState<_ClientePinSheet> {
  late final Future<String?> _fotoUrl;
  late final Future<List<_ContratoCuota>> _contratos;

  String get _clienteId => widget.row['id'] as String;

  @override
  void initState() {
    super.initState();
    _fotoUrl = _cargarFoto();
    _contratos = widget.esTecnico
        ? Future.value(const <_ContratoCuota>[])
        : _cargarContratosConCuota();
  }

  /// URL firmada de la PRIMERA foto del cliente (la galería que ya existe).
  Future<String?> _cargarFoto() async {
    try {
      final rows = await ps.db.getAll(
        'SELECT storage_path FROM fotos_cliente WHERE cliente_id = ? '
        'ORDER BY created_at ASC LIMIT 1',
        [_clienteId],
      );
      if (rows.isEmpty) return null;
      final path = rows.first['storage_path'] as String;
      return await Supabase.instance.client.storage
          .from('fotos-clientes')
          .createSignedUrl(path, 86400);
    } catch (_) {
      return null; // sin foto / sin red: la UI cae a un placeholder
    }
  }

  /// Un row por contrato activo que tenga cuota pendiente, con su cuota MÁS
  /// VIEJA (la que se cobraría). Ordenados por antigüedad del contrato.
  Future<List<_ContratoCuota>> _cargarContratosConCuota() async {
    final rows = await ps.db.getAll(
      '''
      SELECT ct.id AS contrato_id, p.nombre AS plan_nombre, ct.dia_pago,
             cu.id AS cuota_id, cu.periodo,
             (cu.monto + COALESCE(cu.cargos_neto, 0) - cu.monto_pagado) AS saldo
        FROM contratos ct
        LEFT JOIN planes p ON p.id = ct.plan_id
        JOIN cuotas cu ON cu.id = (
             SELECT cu2.id FROM cuotas cu2
              WHERE cu2.contrato_id = ct.id
                AND cu2.estado IN ('pendiente','parcial')
              ORDER BY cu2.fecha_vencimiento ASC, cu2.periodo ASC
              LIMIT 1)
       WHERE ct.cliente_id = ?
         AND COALESCE(ct.estado, 'activo') = 'activo'
       ORDER BY ct.fecha_inicio ASC
      ''',
      [_clienteId],
    );
    return rows
        .map((r) => (
              contratoId: r['contrato_id'] as String,
              planNombre: r['plan_nombre'] as String?,
              diaPago: (r['dia_pago'] as num?)?.toInt(),
              cuotaId: r['cuota_id'] as String,
              periodo: r['periodo'] as String,
              saldo: ((r['saldo'] as num?) ?? 0).toDouble(),
            ))
        .toList();
  }

  Future<void> _llamar(String tel) async {
    final uri = Uri(scheme: 'tel', path: tel.replaceAll(RegExp(r'[^0-9+]'), ''));
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _ruta() async {
    final lat = (widget.row['latitud'] as num).toDouble();
    final lng = (widget.row['longitud'] as num).toDouble();
    final uri = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _irACobro(String cuotaId) {
    Navigator.pop(context); // cierra el sheet
    context.push('/cobro/$cuotaId');
  }

  /// Botón "Pagar": 1 contrato → directo a la cuota; 2+ → selector de servicio.
  Future<void> _pagar(List<_ContratoCuota> contratos) async {
    if (contratos.length == 1) {
      _irACobro(contratos.first.cuotaId);
      return;
    }
    final elegido = await showModalBottomSheet<_ContratoCuota>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('¿Qué servicio cobrás?',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            for (final c in contratos)
              ListTile(
                leading: const Icon(Icons.wifi),
                title: Text(c.planNombre ?? 'Servicio'),
                subtitle: Text(
                    '${Fmt.mesServicioLabel(DateTime.parse(c.periodo), c.diaPago)} · ${Fmt.cordobas(c.saldo)}'),
                onTap: () => Navigator.pop(context, c),
              ),
          ],
        ),
      ),
    );
    if (elegido != null && mounted) _irACobro(elegido.cuotaId);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = widget.row;
    final nombre = r['nombre'] as String;
    final tel = (r['telefono'] as String?)?.trim();
    final direccion = (r['direccion'] as String?)?.trim();
    final referencia = (r['direccion_referencia'] as String?)?.trim();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Foto de la casa (primera de la galería).
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: FutureBuilder<String?>(
                  future: _fotoUrl,
                  builder: (_, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return Container(
                        color: scheme.surfaceContainerHighest,
                        child: const Center(
                            child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))),
                      );
                    }
                    final url = snap.data;
                    if (url == null) {
                      return Container(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(Icons.home_outlined,
                            size: 48, color: scheme.outline),
                      );
                    }
                    return Image.network(url, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) {
                      return Container(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(Icons.broken_image_outlined,
                            size: 40, color: scheme.outline),
                      );
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(nombre, style: Theme.of(context).textTheme.titleMedium),
            // Teléfono con botón de llamar.
            if (tel != null && tel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(Icons.phone, size: 16, color: scheme.outline),
                    const SizedBox(width: 8),
                    Expanded(child: Text(tel)),
                    TextButton.icon(
                      icon: const Icon(Icons.call, size: 18),
                      label: const Text('Llamar'),
                      onPressed: () => _llamar(tel),
                    ),
                  ],
                ),
              ),
            if (direccion != null && direccion.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.location_on_outlined,
                        size: 16, color: scheme.outline),
                    const SizedBox(width: 8),
                    Expanded(child: Text(direccion)),
                  ],
                ),
              ),
            if (referencia != null && referencia.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.signpost_outlined,
                        size: 16, color: scheme.outline),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(referencia,
                            style: TextStyle(color: scheme.outline))),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            // Acciones secundarias: Ruta + Ver cliente.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.directions, size: 18),
                    label: const Text('Ruta'),
                    onPressed: _ruta,
                  ),
                ),
                if (!widget.esTecnico) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.person_outline, size: 18),
                      label: const Text('Ver cliente'),
                      onPressed: () {
                        Navigator.pop(context);
                        context.push('/clientes/$_clienteId');
                      },
                    ),
                  ),
                ],
              ],
            ),
            // Botón principal: Pagar la cuota más vieja.
            if (!widget.esTecnico)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FutureBuilder<List<_ContratoCuota>>(
                  future: _contratos,
                  builder: (_, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const FilledButton(
                          onPressed: null, child: Text('Cargando cuotas…'));
                    }
                    final cuotas = snap.data ?? const [];
                    if (cuotas.isEmpty) {
                      return const FilledButton(
                          onPressed: null,
                          child: Text('Sin cuotas pendientes'));
                    }
                    final unica = cuotas.length == 1;
                    final label = unica
                        ? 'Pagar ${Fmt.mesServicioLabel(DateTime.parse(cuotas.first.periodo), cuotas.first.diaPago)} · ${Fmt.cordobas(cuotas.first.saldo)}'
                        : 'Pagar cuota (${cuotas.length} servicios)';
                    return FilledButton.icon(
                      icon: const Icon(Icons.payments),
                      label: Text(label),
                      onPressed: () => _pagar(cuotas),
                    );
                  },
                ),
              ),
          ],
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

/// Fila de chips de filtro por estado de cobranza, sobre el mapa. Cada chip de
/// estado lleva un punto con el color configurado (leyenda viva). "Ver todo"
/// (que revela fuera-de-rango y sin-deuda) solo aparece para la vista admin.
class _FiltroChips extends StatelessWidget {
  const _FiltroChips({
    required this.seleccionado,
    required this.onChanged,
    required this.colores,
    required this.esAdmin,
  });

  final _FiltroEstado seleccionado;
  final ValueChanged<_FiltroEstado> onChanged;
  final ColoresEstados colores;
  final bool esAdmin;

  // (filtro, label, color del punto). null = sin punto (Pendientes / Ver todo).
  List<(_FiltroEstado, String, Color?)> _opciones() => [
        (_FiltroEstado.pendientes, 'Pendientes', null),
        (_FiltroEstado.mora, 'En mora', colores.mora),
        (_FiltroEstado.gracia, 'En gracia', colores.gracia),
        (_FiltroEstado.hoy, 'Vencen hoy', colores.hoy),
        (_FiltroEstado.proxima, 'Próximas', colores.proxima),
        if (esAdmin) (_FiltroEstado.verTodo, 'Ver todo', null),
      ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final (estado, label, punto) in _opciones())
          ChoiceChip(
            label: Text(label),
            avatar: punto == null
                ? null
                : CircleAvatar(backgroundColor: punto, radius: 6),
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
    required this.nodoId,
    required this.cobradorOpciones,
    required this.comunidadOpciones,
    required this.nodoOpciones,
    required this.onCobradorChanged,
    required this.onComunidadChanged,
    required this.onNodoChanged,
  });

  final String? cobradorId;
  final String? comunidadId;
  final String? nodoId;
  final List<({String id, String label})> cobradorOpciones;
  final List<({String id, String label})> comunidadOpciones;
  final List<({String id, String label})> nodoOpciones;
  final ValueChanged<String?> onCobradorChanged;
  final ValueChanged<String?> onComunidadChanged;
  final ValueChanged<String?> onNodoChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        DropdownFiltro(
          icon: Icons.person_outline,
          hint: 'Cobrador',
          todosLabel: 'Todos',
          value: cobradorId,
          opciones: cobradorOpciones,
          onChanged: onCobradorChanged,
        ),
        DropdownFiltro(
          icon: Icons.place_outlined,
          hint: 'Zona',
          todosLabel: 'Todas',
          value: comunidadId,
          opciones: comunidadOpciones,
          onChanged: onComunidadChanged,
        ),
        DropdownFiltro(
          icon: Icons.hub_outlined,
          hint: 'Nodo',
          todosLabel: 'Todos',
          value: nodoId,
          opciones: nodoOpciones,
          onChanged: onNodoChanged,
        ),
      ],
    );
  }
}

/// Banner que reemplaza los filtros cuando hay un cliente enfocado por la
/// búsqueda: muestra su nombre y una X para volver a ver todos los pines.
class _BannerSeleccion extends StatelessWidget {
  const _BannerSeleccion({required this.nombre, required this.onClear});

  final String nombre;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.place, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                nombre,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              visualDensity: VisualDensity.compact,
              tooltip: 'Ver todos',
              onPressed: onClear,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet para buscar un cliente por nombre entre los que tienen
/// ubicación. Devuelve la fila elegida (o null si se cierra sin elegir).
class _BuscadorClientes extends StatefulWidget {
  const _BuscadorClientes({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  State<_BuscadorClientes> createState() => _BuscadorClientesState();
}

class _BuscadorClientesState extends State<_BuscadorClientes> {
  String _q = '';

  /// Matchea por nombre, cédula, teléfono, código de cliente y código de
  /// contrato (mismos criterios que la lista de clientes). Para el teléfono
  /// además compara solo dígitos, así "8888-8888" matchea "88888888".
  bool _matches(Map<String, dynamic> r, String q) {
    if (q.isEmpty) return true;
    final hay = [
      r['nombre'],
      r['cedula'],
      r['telefono'],
      r['codigo'],
      r['contrato_codigos'],
    ].whereType<String>().join(' ').toLowerCase();
    if (hay.contains(q)) return true;
    final qDigits = q.replaceAll(RegExp(r'\D'), '');
    if (qDigits.isNotEmpty) {
      final telDigits =
          (r['telefono'] as String?)?.replaceAll(RegExp(r'\D'), '') ?? '';
      if (telDigits.contains(qDigits)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final filtradas = widget.rows.where((r) => _matches(r, _q)).toList()
      ..sort((a, b) => (a['nombre'] as String)
          .toLowerCase()
          .compareTo((b['nombre'] as String).toLowerCase()));

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Nombre, cédula, teléfono o código',
            ),
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
          ),
          const SizedBox(height: 8),
          if (filtradas.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Sin clientes con ubicación que coincidan'),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: filtradas.length,
                itemBuilder: (_, i) {
                  final r = filtradas[i];
                  // Subtítulo: código de cliente + comunidad, para desambiguar
                  // homónimos al buscar por nombre.
                  final sub = [r['codigo'], r['comunidad']]
                      .whereType<String>()
                      .where((s) => s.isNotEmpty)
                      .join(' · ');
                  return ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(r['nombre'] as String),
                    subtitle: sub.isEmpty ? null : Text(sub),
                    onTap: () => Navigator.pop(context, r),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _UbicacionActualMarker extends StatefulWidget {
  const _UbicacionActualMarker();

  @override
  State<_UbicacionActualMarker> createState() => _UbicacionActualMarkerState();
}

class _UbicacionActualMarkerState extends State<_UbicacionActualMarker>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final value = _controller.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 14 + (26 * value),
              height: 14 + (26 * value),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blue.withValues(alpha: 0.4 * (1.0 - value)),
              ),
            ),
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blue.shade600,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 3,
                    offset: Offset(0, 1.5),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

