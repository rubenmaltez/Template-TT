import 'dart:typed_data';

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
