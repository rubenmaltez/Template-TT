import 'dart:typed_data';

/// Método de codificación de la imagen a comandos de impresora. Distintas
/// térmicas soportan distintos comandos / polaridad de bits; este enum permite
/// A/B-testear cuál funciona en CADA modelo sin adivinar.
enum MetodoRaster {
  /// GS v 0 (raster bit image) armado a mano. 1 = punto negro (quema). El más
  /// universal en impresoras modernas. Apuesta principal.
  gsv0,

  /// GS v 0 con la polaridad INVERTIDA (1 = blanco). Para impresoras cuyo raster
  /// sale en negativo con el modo estándar.
  gsv0Invertido,

  /// ESC * (bit image por columnas) vía la librería. Para impresoras viejas que
  /// no soportan GS v 0.
  escPosColumnas,
}

/// Resultado del diagnóstico de impresión: deja VER exactamente qué bitmap
/// produce la captura del recibo y qué bitmap termina yendo a la térmica.
///
/// - [rawPng]      → el PNG TAL CUAL lo devolvió la captura del widget
///                   (`captureFromWidget`), sin tocar.
/// - [procesadaPng]→ el bitmap FINAL que se manda a `imageRaster` (después de
///                   aplanar sobre blanco + grises + recorte vertical + dither),
///                   re-encodeado a PNG solo para poder mirarlo.
/// - [info]        → métricas concretas (ancho×alto, alpha, luminancia de
///                   esquina/centro) para diagnosticar sin adivinar.
///
/// Comparar las dos imágenes dice DÓNDE está el problema: si la cruda ya viene
/// oscura/angosta → es la captura; si la cruda está bien pero la procesada se
/// daña → es el pipeline.
class DiagnosticoImpresion {
  const DiagnosticoImpresion({
    required this.rawPng,
    required this.procesadaPng,
    required this.info,
  });

  final Uint8List rawPng;
  final Uint8List procesadaPng;
  final String info;
}
