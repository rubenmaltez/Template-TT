import 'package:supabase_flutter/supabase_flutter.dart';

/// Invoca una Edge Function de Supabase y devuelve el body parseado
/// con manejo unificado de errores (R14).
///
/// Convención del proyecto: las Edge Functions devuelven
/// `{ok: bool, error?: String, ...}`. Este helper extrae el mensaje
/// real del campo `error` tanto en respuestas 200-ok=false como en
/// `FunctionException` (status != 200), evitando que el caller vea
/// el wrapper técnico `'FunctionException(status: 409, details:…)'`.
///
/// - Lanza `Exception(<mensaje legible>)` en caso de error.
/// - Retorna `Map<String, dynamic>` en caso de éxito (con `ok: true`
///   garantizado).
Future<Map<String, dynamic>> invokeEdgeFunction(
  SupabaseClient client,
  String name, {
  Map<String, dynamic>? body,
}) async {
  try {
    final res = await client.functions.invoke(name, body: body);
    final data = res.data as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('Sin respuesta del servidor');
    }
    if (data['ok'] != true) {
      throw Exception(
          (data['error'] as String?) ?? 'Error desconocido');
    }
    return data;
  } on FunctionException catch (e) {
    // Edge Function devolvió 4xx/5xx — el body parseado vive en
    // e.details. Extraemos el campo 'error' si está; sino fallback al
    // status para no mostrar string vacío.
    final det = e.details;
    String? mensaje;
    if (det is Map && det['error'] != null) {
      mensaje = det['error'].toString();
    }
    throw Exception(mensaje ?? 'Error ${e.status}');
  }
}
