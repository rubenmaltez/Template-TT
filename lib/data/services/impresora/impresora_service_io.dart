import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

/// Información de una impresora Bluetooth pareada.
class ImpresoraBT {
  const ImpresoraBT({required this.nombre, required this.mac});
  final String nombre;
  final String mac;
}

/// Servicio para imprimir recibos en impresoras térmicas Bluetooth.
///
/// El recibo se imprime como IMAGEN: el call-site CAPTURA el widget Flutter
/// `ReciboTicket` a PNG (con `screenshot`) y nos lo pasa. Lo decodificamos,
/// lo pasamos a monocromo con dithering y lo enviamos como raster ESC/POS.
/// Como lo renderiza Skia (el mismo motor que dibuja la pantalla), las tildes
/// salen perfectas en CUALQUIER impresora — no depende del codepage del modelo
/// ni de una fuente embebida. Es 100% OFFLINE y la preview = lo que se imprime.
///
/// Mobile only — web tiene un stub paralelo.
class ImpresoraService {
  bool get soportado => true;

  Future<bool> isBluetoothEnabled() async {
    try {
      return await PrintBluetoothThermal.bluetoothEnabled;
    } catch (_) {
      return false;
    }
  }

  /// Lista impresoras BT pareadas en el sistema operativo. NO escanea.
  Future<List<ImpresoraBT>> listarPareadas() async {
    final raw = await PrintBluetoothThermal.pairedBluetooths;
    return raw
        // ignore: deprecated_member_use — typo del paquete (macAdress).
        .map((b) => ImpresoraBT(nombre: b.name, mac: b.macAdress))
        .toList();
  }

  /// Imprime una IMAGEN (PNG) ya renderizada por el call-site (captura del
  /// widget `ReciboTicket` vía `screenshot`). Devuelve true al éxito.
  ///
  /// [pngBytes] = PNG del recibo. Idealmente ya viene al ancho exacto del papel
  /// (capturado con `targetSize` = dots), pero igual reescalamos por seguridad.
  /// [anchoMm] = 58 u 80 (ancho del papel).
  ///
  /// Flujo OFFLINE: decodifica el PNG en memoria (sin red), monocromo +
  /// dithering, y lo emite como raster **GS v 0 armado a mano** (polaridad
  /// 1=negro y ancho explícitos). Se eligió GS v 0 manual sobre `gen.imageRaster`
  /// porque este último codificaba mal en algunas térmicas (salía negativo/
  /// angosto) — confirmado en campo (GOOJPRT PT-210). Si algo falla, false.
  Future<bool> imprimirImagen({
    required String macImpresora,
    required Uint8List pngBytes,
    required int anchoMm,
  }) async {
    try {
      final imagen = _procesarParaTermica(pngBytes, anchoMm);
      if (imagen == null) {
        if (kDebugMode) debugPrint('Impresora imagen: PNG no decodificable');
        return false;
      }

      final bytes = <int>[
        // Reset/init (ESC @): limpia el buffer y deja la térmica en estado
        // conocido (saca cualquier modo raro previo).
        0x1B, 0x40,
        ..._rasterGsv0(imagen),
        // Avance de papel mínimo para cortar/arrancar sin perder la última
        // línea + corte. ESC d 2 = avanza 2 líneas; GS V 0 = corte total
        // (inofensivo si la impresora no tiene cutter, lo ignora).
        0x1B, 0x64, 0x02, 0x1D, 0x56, 0x00,
      ];

      return _enviarBytes(macImpresora, bytes);
    } catch (e) {
      if (kDebugMode) debugPrint('Impresora imagen: $e');
      return false;
    }
  }

  /// Arma el comando GS v 0 (raster bit image) A MANO desde una imagen en
  /// grises/dither. Control TOTAL de:
  ///   - polaridad: 1 = punto negro (quema).
  ///   - ancho en bytes: (w+7)>>3, header xL/xH correcto.
  ///   - se parte en BANDAS (≤255 filas) para no exceder el buffer de la
  ///     térmica (algunas truncan rasters muy altos).
  /// Umbral 0.5 sobre luminancia: la imagen ya viene dithered (casi B/N).
  static List<int> _rasterGsv0(img.Image im) {
    final w = im.width;
    final h = im.height;
    final widthBytes = (w + 7) >> 3;
    final out = <int>[];
    const banda = 255; // filas por comando GS v 0
    for (var y0 = 0; y0 < h; y0 += banda) {
      final filas = (y0 + banda <= h) ? banda : (h - y0);
      final raster = Uint8List(widthBytes * filas);
      for (var y = 0; y < filas; y++) {
        for (var x = 0; x < w; x++) {
          if (im.getPixel(x, y0 + y).luminanceNormalized < 0.5) {
            raster[y * widthBytes + (x >> 3)] |= (0x80 >> (x & 7));
          }
        }
      }
      // GS v 0  m=0  xL xH  yL yH  [data]
      out.addAll(<int>[
        0x1D, 0x76, 0x30, 0x00,
        widthBytes & 0xff, (widthBytes >> 8) & 0xff,
        filas & 0xff, (filas >> 8) & 0xff,
      ]);
      out.addAll(raster);
    }
    return out;
  }

  /// Pipeline captura→bitmap-térmico (decode → aplanar sobre blanco → resize a
  /// dots → grayscale → recortar blanco → dither Floyd-Steinberg). Devuelve null
  /// si el PNG no decodifica.
  img.Image? _procesarParaTermica(Uint8List pngBytes, int anchoMm) {
    // Ancho útil en dots según el papel: 58mm ≈ 384 px, 80mm = 576 px
    // (anchos estándar ESC/POS). 80mm es el estándar de producción.
    final anchoDots = anchoMm >= 80 ? 576 : 384;

    img.Image? imagen = img.decodeImage(pngBytes);
    if (imagen == null) return null;

    // Aplanar sobre fondo BLANCO opaco. La captura del widget (`screenshot`)
    // viene con canal alpha (toImage produce RGBA); sin esto, al pasar a grises
    // las zonas transparentes quedan NEGRAS y la térmica las quema → recibo en
    // NEGATIVO (fondo negro). Aplanar = transparente se vuelve blanco, así el
    // recorte funciona y el recibo sale en positivo.
    if (imagen.hasAlpha) {
      final fondo = img.Image(width: imagen.width, height: imagen.height);
      img.fill(fondo, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(fondo, imagen);
      imagen = fondo;
    }

    // Si la captura quedó más ancha/angosta que el papel, reescalar al ancho
    // de dots (mantiene aspecto recalculando el alto). Normalmente la captura
    // ya viene a `anchoDots` (targetSize) y esto es un no-op.
    if (imagen.width != anchoDots) {
      imagen = img.copyResize(imagen, width: anchoDots);
    }

    // Monocromo limpio: grayscale + dithering Floyd-Steinberg. La térmica
    // solo imprime negro/blanco; el dither evita bloques tiznados.
    imagen = img.grayscale(imagen);
    // Recortar el margen blanco arriba/abajo (la captura puede venir con alto
    // holgado/centrado por el targetSize) → no se imprime tira en blanco y se
    // aprovecha el papel.
    imagen = _recortarBlancoVertical(imagen);
    imagen = img.ditherImage(
      imagen,
      kernel: img.DitherKernel.floydSteinberg,
    );
    return imagen;
  }

  /// Recorta el margen BLANCO de arriba y abajo de una imagen en grises, para
  /// que la térmica no imprima tira en blanco (la captura puede venir con alto
  /// holgado por el `targetSize`). Deja un pequeño padding. Si la imagen es
  /// toda blanca, la devuelve sin tocar.
  static img.Image _recortarBlancoVertical(img.Image im) {
    bool filaConContenido(int y) {
      for (var x = 0; x < im.width; x++) {
        // luminanceNormalized: 0 (negro) … 1 (blanco). < 0.95 = hay tinta.
        if (im.getPixel(x, y).luminanceNormalized < 0.95) return true;
      }
      return false;
    }

    var top = 0;
    var bottom = im.height - 1;
    while (top < im.height && !filaConContenido(top)) {
      top++;
    }
    while (bottom > top && !filaConContenido(bottom)) {
      bottom--;
    }
    if (top >= bottom) return im; // todo blanco → no recortar

    // Padding mínimo arriba/abajo (≈0.5mm) para aprovechar el papel sin que
    // las ascendentes/descendentes queden al ras del borde.
    const pad = 4;
    final y0 = (top - pad) < 0 ? 0 : (top - pad);
    var alto = (bottom - top + 1) + pad * 2;
    if (y0 + alto > im.height) alto = im.height - y0;
    return img.copyCrop(im, x: 0, y: y0, width: im.width, height: alto);
  }

  /// Imprime un recibo de prueba para validar conexión + papel.
  ///
  /// ASCII-only (sin tildes) a propósito: es solo un test de conexión, no debe
  /// depender del codepage del modelo. El reset ESC @ saca la térmica de
  /// cualquier modo raro antes del texto.
  Future<bool> imprimirPrueba({
    required String macImpresora,
    required int anchoMm,
  }) async {
    final profile = await CapabilityProfile.load();
    final gen = Generator(_size(anchoMm), profile);
    final bytes = <int>[
      // Reset/init ANTES del primer texto.
      0x1B, 0x40,
      ...gen.text('PRUEBA DE IMPRESION',
          styles: const PosStyles(align: PosAlign.center, bold: true)),
      ...gen.feed(1),
      ...gen.text('Si lees esto la impresora esta OK',
          styles: const PosStyles(align: PosAlign.center)),
      ...gen.feed(3),
      ...gen.cut(),
    ];
    return _enviarBytes(macImpresora, bytes);
  }

  /// Conecta → escribe → desconecta. Maneja errores silenciosos.
  Future<bool> _enviarBytes(String mac, List<int> bytes) async {
    try {
      final ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
      if (!ok) return false;
      final result = await PrintBluetoothThermal.writeBytes(bytes);
      await PrintBluetoothThermal.disconnect;
      return result;
    } catch (e) {
      if (kDebugMode) debugPrint('Impresora: $e');
      try {
        await PrintBluetoothThermal.disconnect;
      } catch (_) {}
      return false;
    }
  }

  PaperSize _size(int mm) => mm >= 80 ? PaperSize.mm80 : PaperSize.mm58;
}
