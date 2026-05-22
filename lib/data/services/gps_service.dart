import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Captura GPS del dispositivo con manejo de permisos y errores.
/// Devuelve null silencioso si no hay permiso o GPS deshabilitado:
/// el cobro continúa sin coordenadas, no bloquea el flujo.
///
/// Permisos requeridos:
///   Android: ACCESS_FINE_LOCATION + ACCESS_COARSE_LOCATION en AndroidManifest.xml
///   iOS:     NSLocationWhenInUseUsageDescription en Info.plist
///   Web:     requiere HTTPS (localhost OK en dev).
class GpsService {
  const GpsService();

  /// Obtiene la ubicación actual. Devuelve null si no es posible
  /// (sin permiso, GPS apagado, timeout, plataforma sin soporte).
  Future<({double lat, double lng})?> obtenerUbicacion({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return null;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(timeout);

      return (lat: pos.latitude, lng: pos.longitude);
    } catch (e) {
      if (kDebugMode) debugPrint('GpsService: $e');
      return null;
    }
  }
}
