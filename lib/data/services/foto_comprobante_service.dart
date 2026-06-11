import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import 'foto_local_storage.dart';

/// Resumen de una corrida de `sincronizarPendientes`. Emitido por el
/// stream `FotoComprobanteService.results` para que la UI surface
/// fallas via SnackBar (R8) sin reventar el flujo offline-first.
///
/// `succeeded` + `failed` son uploads reales intentados. Los skip
/// (path sospechoso, archivo local desaparecido) NO se cuentan acá —
/// no son fallas del sync, son cleanup automático.
class UploadResult {
  const UploadResult({
    required this.succeeded,
    required this.failed,
    this.lastErrorMessage,
  });

  final int succeeded;
  final int failed;
  final String? lastErrorMessage;
}

/// Manejo de fotos del comprobante de pago.
///
/// Flujo offline-first:
///   1. capturar(): toma/elige foto, la comprime y la guarda en disco local
///      con un nombre persistente. Devuelve un path con prefijo `local://`
///      que se guarda en `pagos.foto_comprobante_path`.
///   2. Cuando PowerSync vuelve a estar online, sincronizarPendientes()
///      barre los pagos con path `local://*`, los sube a Storage y
///      actualiza el path al definitivo.
///
/// El bucket Storage es `comprobantes-pago` y la convención de path final
/// es `{tenant_id}/comp/{pago_id}.jpg` (ver migración 0019).
///
/// Cross-platform: en web el storage local no aplica (no hay filesystem
/// persistente) — la captura no funciona ahí, sólo la VISUALIZACIÓN remota.
class FotoComprobanteService {
  FotoComprobanteService(this._supabase);
  final SupabaseClient _supabase;
  final _picker = ImagePicker();
  static const _bucket = 'comprobantes-pago';
  static const _prefijoLocal = 'local://';

  // Flag de corrida única ESTÁTICO: compartido entre TODAS las instancias
  // (worker en main.dart y el provider Riverpod podrían instanciar el
  // servicio por separado). Previene doble upload del mismo path.
  //
  // R8 nota: para que el stream `results` sea único (sino tendríamos dos
  // streams separados, uno por instancia, y la UI watchearía uno mientras
  // el worker emite al otro), el servicio se debe consumir SIEMPRE vía
  // `fotoComprobanteServiceProvider`. main.dart ya hace container.read.
  static bool _sincronizando = false;

  /// Broadcast del resultado de cada corrida con upload real (no se
  /// emite cuando no hubo pendientes elegibles).
  ///
  /// Tiene throttle interno: si el último resultado con `failed > 0`
  /// se emitió hace menos de `_throttleErrores`, no re-emitimos —
  /// evita spam de SnackBars cuando hay un error estructural
  /// (token expirado, bucket caído) y PowerSync reconecta cada pocos
  /// segundos. El éxito siempre se emite y resetea el throttle.
  final _results = StreamController<UploadResult>.broadcast();
  // Replay del último resultado para nuevos suscriptores: si la UI se
  // desmonta/remonta (navegación entre pantallas) o el provider se
  // re-suscribe, el suscriptor recibe el último resultado inmediatamente
  // en vez de esperar al próximo ciclo de sync.
  //
  // R8 follow-up: el último resultado CON fallas se persiste además en
  // SharedPreferences — un F5/restart ya no lo pierde (el cobrador ve el
  // aviso de fotos fallidas al reabrir). Un éxito limpio borra la clave.
  UploadResult? _lastResult;
  static const _kLastResultKey = 'foto_upload_last_result';

  Stream<UploadResult> get results async* {
    if (_lastResult == null) {
      await _restaurarLastResult();
    }
    if (_lastResult != null) yield _lastResult!;
    yield* _results.stream;
  }

  Future<void> _restaurarLastResult() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLastResultKey);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      _lastResult = UploadResult(
        succeeded: (m['succeeded'] as num?)?.toInt() ?? 0,
        failed: (m['failed'] as num?)?.toInt() ?? 0,
        lastErrorMessage: m['lastErrorMessage'] as String?,
      );
    } catch (_) {
      // Prefs corruptas/inaccesibles → seguir sin replay (no es crítico).
    }
  }

  Future<void> _persistirLastResult(UploadResult r) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (r.failed > 0) {
        await prefs.setString(
            _kLastResultKey,
            jsonEncode({
              'succeeded': r.succeeded,
              'failed': r.failed,
              'lastErrorMessage': r.lastErrorMessage,
            }));
      } else {
        // Corrida limpia → ya no hay falla pendiente que recordar.
        await prefs.remove(_kLastResultKey);
      }
    } catch (_) {
      // Best-effort: si prefs falla, el replay en memoria sigue funcionando.
    }
  }

  static const _throttleErrores = Duration(minutes: 2);
  DateTime? _ultimaEmisionError;

  /// Toma una foto con cámara o galería, la comprime y la guarda en disco
  /// local. Devuelve el path con prefijo `local://`. Null si el usuario
  /// canceló o si la plataforma no soporta storage local.
  Future<String?> capturar({required ImageSource source}) async {
    final XFile? raw = await _picker.pickImage(
      source: source,
      imageQuality: 70,
      maxWidth: 1600,
      maxHeight: 1600,
    );
    if (raw == null) return null;

    final bytes = await raw.readAsBytes();
    final nombre = '${const Uuid().v4()}.jpg';
    final ok = await FotoLocalStorage.save(bytes, nombre);
    if (!ok) return null;

    return '$_prefijoLocal$nombre';
  }

  /// Resuelve un path almacenado en `pagos.foto_comprobante_path` a bytes
  /// si existe localmente. Devuelve null si el path es remoto o no existe.
  ///
  /// Valida que el nombre sea un UUID + extensión sin path traversal.
  Future<Uint8List?> bytesLocal(String? pathBd) async {
    if (pathBd == null || !pathBd.startsWith(_prefijoLocal)) return null;
    final nombre = pathBd.substring(_prefijoLocal.length);
    if (!_nombreSeguro(nombre)) return null;
    return FotoLocalStorage.read(nombre);
  }

  /// Sube las fotos pendientes (filtra `anulado = 0`).
  /// Lock de corrida única: si ya está sincronizando, retorna 0 sin hacer
  /// nada — compatible con disparos simultáneos desde worker y UI.
  Future<int> sincronizarPendientes() async {
    if (_sincronizando) return 0;
    _sincronizando = true;
    try {
      return await _sincronizarImpl();
    } finally {
      _sincronizando = false;
    }
  }

  Future<int> _sincronizarImpl() async {
    final pendientes = await ps.db.getAll(
      "SELECT id, tenant_id, foto_comprobante_path "
      "FROM pagos "
      "WHERE foto_comprobante_path LIKE 'local://%' AND anulado = 0",
    );

    // Sin pendientes no hay nada que avisar: limpiar el resumen persistido.
    // Cubre el caso "la foto fallida desapareció por cleanup" (archivo local
    // borrado → path NULL) — sin esto, la clave de prefs replayaba un aviso
    // de falla referido a nada en cada restart.
    if (pendientes.isEmpty) {
      if (_lastResult != null && _lastResult!.failed > 0) _lastResult = null;
      unawaited(_persistirLastResult(
          const UploadResult(succeeded: 0, failed: 0)));
      return 0;
    }

    var subidas = 0;
    var fallidas = 0;
    String? ultimoError;
    var huboUploadIntentado = false;

    for (final row in pendientes) {
      final pagoId = row['id'] as String;
      final tenantId = row['tenant_id'] as String;
      final pathLocal = row['foto_comprobante_path'] as String;
      final nombre = pathLocal.substring(_prefijoLocal.length);

      if (!_nombreSeguro(nombre)) {
        // Path sospechoso (vino mal de otro dispositivo o admin malicioso).
        await ps.db.execute(
          "UPDATE pagos SET foto_comprobante_path = NULL WHERE id = ?",
          [pagoId],
        );
        continue;
      }

      try {
        final bytes = await FotoLocalStorage.read(nombre);
        if (bytes == null) {
          // El archivo local desapareció (otro dispositivo, reinstall, etc.).
          // Limpiar referencia.
          await ps.db.execute(
            "UPDATE pagos SET foto_comprobante_path = NULL "
            "WHERE id = ? AND foto_comprobante_path LIKE 'local://%'",
            [pagoId],
          );
          continue;
        }

        huboUploadIntentado = true;
        final pathRemoto = '$tenantId/comp/$pagoId.jpg';
        await _supabase.storage.from(_bucket).uploadBinary(
              pathRemoto,
              bytes,
              fileOptions: const FileOptions(
                upsert: true,
                contentType: 'image/jpeg',
              ),
            );

        // El WHERE protege contra una segunda corrida que ya hubiera
        // actualizado el path.
        await ps.db.execute(
          "UPDATE pagos SET foto_comprobante_path = ? "
          "WHERE id = ? AND foto_comprobante_path LIKE 'local://%'",
          [pathRemoto, pagoId],
        );
        await FotoLocalStorage.delete(nombre);
        subidas++;
      } catch (e) {
        if (kDebugMode) debugPrint('Foto $pagoId no subió aún: $e');
        fallidas++;
        ultimoError = e.toString();
        // Continuar — reintenta en próximo sync.
      }
    }

    // R8: emitimos el summary sólo si hubo intento real de upload. Sin
    // pendientes elegibles (o todos eran skip de cleanup) → silencio,
    // no spam de SnackBars en cada heartbeat de PowerSync.
    if (huboUploadIntentado) {
      final result = UploadResult(
        succeeded: subidas,
        failed: fallidas,
        lastErrorMessage: ultimoError,
      );
      if (_debeEmitir(result)) {
        _lastResult = result;
        _results.add(result);
        unawaited(_persistirLastResult(result));
      }
    }
    return subidas;
  }

  /// Throttle de la emisión: las corridas exitosas siempre se emiten
  /// (resetean el contador), pero las corridas con failures se filtran
  /// si fue muy poco después de la última. Sino un error estructural
  /// dispara un SnackBar por cada reconexión, lo cual en redes
  /// intermitentes es insufrible.
  bool _debeEmitir(UploadResult result) {
    if (result.failed == 0) {
      _ultimaEmisionError = null;
      return true;
    }
    final ahora = DateTime.now();
    final ultima = _ultimaEmisionError;
    if (ultima != null && ahora.difference(ultima) < _throttleErrores) {
      return false;
    }
    _ultimaEmisionError = ahora;
    return true;
  }

  /// Genera URL firmada para mostrar la foto desde Storage. TTL 1h.
  Future<String?> urlFirmada(String pathRemoto) async {
    try {
      return await _supabase.storage
          .from(_bucket)
          .createSignedUrl(pathRemoto, 3600);
    } catch (e) {
      if (kDebugMode) debugPrint('urlFirmada: $e');
      return null;
    }
  }

  /// Garbage collection: borra archivos locales que no tienen referencia
  /// activa en `pagos.foto_comprobante_path`. Casos típicos: cobrador
  /// canceló un cobro tras adjuntar foto, o el pago ya se sincronizó al
  /// path remoto y el archivo local quedó.
  Future<int> limpiarHuerfanos() async {
    final archivos = await FotoLocalStorage.listAll();
    if (archivos.isEmpty) return 0;

    final refs = await ps.db.getAll(
      "SELECT foto_comprobante_path FROM pagos "
      "WHERE foto_comprobante_path LIKE 'local://%'",
    );
    final usados = refs
        .map((r) => (r['foto_comprobante_path'] as String).substring(_prefijoLocal.length))
        .toSet();

    var borrados = 0;
    for (final f in archivos) {
      if (!usados.contains(f)) {
        if (await FotoLocalStorage.delete(f)) borrados++;
      }
    }
    return borrados;
  }

  /// Nombre seguro: UUID v4 + extensión, sin separadores ni `..`.
  bool _nombreSeguro(String nombre) {
    if (nombre.contains('/') || nombre.contains('\\') || nombre.contains('..')) {
      return false;
    }
    // UUID + .jpg típicamente 40 chars, dejamos margen.
    return nombre.length >= 5 && nombre.length <= 64;
  }
}
