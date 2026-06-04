import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:printing/printing.dart';

/// Información de una impresora Bluetooth pareada.
class ImpresoraBT {
  const ImpresoraBT({required this.nombre, required this.mac});
  final String nombre;
  final String mac;
}

/// Servicio para imprimir recibos en impresoras térmicas Bluetooth.
///
/// El recibo se imprime como IMAGEN: se rasteriza el PDF del recibo (que ya
/// usa la fuente NotoSans embebida) con el motor PDF local (PDFium, sin red)
/// y se envía como raster ESC/POS. Esto hace que las tildes salgan bien en
/// CUALQUIER impresora — no depende del codepage del modelo. Es 100% OFFLINE.
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

  /// Imprime un recibo rasterizando su PDF a imagen y enviándolo como raster
  /// ESC/POS. Devuelve true al éxito.
  ///
  /// [pdfBytes] = el PDF del recibo YA construido por el call-site (mismos
  /// builders que el "Descargar PDF": NotoSans embebida + logo del cache local).
  /// [anchoMm] = 58 u 80 (ancho del papel).
  ///
  /// Flujo OFFLINE: `Printing.raster` usa PDFium local (sin red); la fuente
  /// está bundleada. Si el raster falla, devuelve false (NO cae a texto
  /// garbleado).
  Future<bool> imprimirRaster({
    required String macImpresora,
    required Uint8List pdfBytes,
    required int anchoMm,
  }) async {
    try {
      // Ancho útil en dots según el papel: 58mm ≈ 384 px, 80mm = 576 px
      // (anchos estándar ESC/POS). 80mm es el estándar de producción.
      final anchoDots = anchoMm >= 80 ? 576 : 384;

      // DPI calculado para que el PDF se renderice EXACTAMENTE al ancho de dots
      // del papel → máxima nitidez sin reescalado (clave para la calidad en
      // 80mm = 576px). pageWidthPt = anchoMm * 2.8346 (1mm ≈ 2.8346 pt);
      // dpi = dots * 72 / pageWidthPt. 80mm → ~183 dpi (576px), 58mm → ~168 dpi
      // (384px). El copyResize de abajo queda solo como red de seguridad por
      // redondeos.
      final dpi = anchoDots * 72.0 / (anchoMm * 2.8346);

      // Recolectar TODAS las páginas del raster. Normalmente el recibo es UNA
      // página (alto `double.infinity`), pero si PDFium parte un recibo muy
      // alto (multi-cuota + mucha mora) en varias, las apilamos verticalmente
      // para NO truncar contenido — un recibo de dinero cortado sería un bug.
      final paginas = <img.Image>[];
      await for (final page in Printing.raster(pdfBytes, dpi: dpi)) {
        // `page.pixels` puede ser una vista con offset sobre un buffer mayor.
        // `Uint8List.fromList` copia SOLO los píxeles de la vista a un buffer
        // fresco en offset 0 → `.buffer` (ByteBuffer) queda alineado y del
        // tipo que espera `Image.fromBytes`.
        paginas.add(img.Image.fromBytes(
          width: page.width,
          height: page.height,
          bytes: Uint8List.fromList(page.pixels).buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        ));
      }
      if (paginas.isEmpty) {
        if (kDebugMode) debugPrint('Impresora raster: PDF sin páginas');
        return false;
      }

      // Una sola página (lo normal) → directo. Varias → apilar vertical para
      // imprimir el recibo completo.
      img.Image imagen =
          paginas.length == 1 ? paginas.first : _apilarVertical(paginas);

      // Si el raster quedó más ancho/angosto que el papel, reescalar al ancho
      // de dots (mantiene aspecto recalculando el alto).
      if (imagen.width != anchoDots) {
        imagen = img.copyResize(imagen, width: anchoDots);
      }

      // Monocromo limpio: grayscale + dithering Floyd-Steinberg → 1-bit. La
      // térmica solo imprime negro/blanco; el dither evita bloques tiznados.
      imagen = img.grayscale(imagen);
      imagen = img.ditherImage(
        imagen,
        kernel: img.DitherKernel.floydSteinberg,
      );

      final gen = Generator(_size(anchoMm), await CapabilityProfile.load());
      final bytes = <int>[
        // Reset/init (ESC @) ANTES del raster: limpia el buffer y deja la
        // térmica en estado conocido.
        0x1B, 0x40,
        ...gen.imageRaster(imagen, align: PosAlign.center),
        ...gen.feed(2),
        ...gen.cut(),
      ];
      return _enviarBytes(macImpresora, bytes);
    } catch (e) {
      if (kDebugMode) debugPrint('Impresora raster: $e');
      return false;
    }
  }

  /// Apila varias imágenes verticalmente (sobre fondo blanco) en una sola.
  /// Se usa cuando PDFium parte un recibo muy alto en varias páginas: las
  /// unimos para imprimir el recibo COMPLETO sin truncar.
  static img.Image _apilarVertical(List<img.Image> imgs) {
    final ancho = imgs.map((i) => i.width).reduce((a, b) => a > b ? a : b);
    final alto = imgs.fold<int>(0, (s, i) => s + i.height);
    final canvas = img.Image(width: ancho, height: alto, numChannels: 4);
    img.fill(canvas, color: img.ColorRgba8(255, 255, 255, 255));
    var y = 0;
    for (final im in imgs) {
      img.compositeImage(canvas, im, dstY: y);
      y += im.height;
    }
    return canvas;
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
