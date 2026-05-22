import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/impresora/impresora_service.dart';

final impresoraServiceProvider = Provider((_) => ImpresoraService());

/// Impresora favorita persistida en SharedPreferences (por dispositivo).
class ImpresoraFavorita {
  const ImpresoraFavorita({required this.mac, required this.nombre});
  final String mac;
  final String nombre;
}

final impresoraFavoritaProvider =
    AsyncNotifierProvider<ImpresoraFavoritaNotifier, ImpresoraFavorita?>(
  ImpresoraFavoritaNotifier.new,
);

class ImpresoraFavoritaNotifier extends AsyncNotifier<ImpresoraFavorita?> {
  static const _keyMac = 'impresora_mac';
  static const _keyNombre = 'impresora_nombre';

  @override
  Future<ImpresoraFavorita?> build() async {
    final prefs = await SharedPreferences.getInstance();
    final mac = prefs.getString(_keyMac);
    final nombre = prefs.getString(_keyNombre);
    if (mac == null || nombre == null) return null;
    return ImpresoraFavorita(mac: mac, nombre: nombre);
  }

  Future<void> guardar(String mac, String nombre) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMac, mac);
    await prefs.setString(_keyNombre, nombre);
    state = AsyncData(ImpresoraFavorita(mac: mac, nombre: nombre));
  }

  Future<void> limpiar() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyMac);
    await prefs.remove(_keyNombre);
    state = const AsyncData(null);
  }
}
