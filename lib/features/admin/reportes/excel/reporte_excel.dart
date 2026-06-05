import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';

/// Construye un archivo Excel (.xlsx) de UNA hoja con encabezado + filas y lo
/// ofrece para descargar/guardar:
///   - Windows: diálogo nativo "Guardar como".
///   - Android: guarda el archivo y devuelve la ruta.
///
/// Pensado para los reportes del admin: reutiliza las mismas queries que ya
/// alimentaban el export CSV, pero produce un .xlsx real (montos como números,
/// no texto, así las sumas funcionan en Excel/Sheets).
///
/// [filas] es una lista de filas; cada celda puede ser `num` (→ celda numérica),
/// `String` (→ texto) o `null` (→ celda vacía). Devuelve la ruta donde se
/// guardó, o `null` si el usuario canceló el diálogo.
Future<String?> descargarExcel({
  required String fileName,
  required String hojaNombre,
  required List<String> headers,
  required List<List<Object?>> filas,
}) async {
  final excel = Excel.createExcel();
  // createExcel arranca con una hoja default ('Sheet1'); la renombramos a algo
  // descriptivo en vez de crear otra y tener que borrar la default.
  final defaultName = excel.getDefaultSheet();
  if (defaultName != null && defaultName != hojaNombre) {
    excel.rename(defaultName, hojaNombre);
  }
  final sheet = excel[hojaNombre];

  sheet.appendRow(headers.map<CellValue?>((h) => TextCellValue(h)).toList());
  for (final fila in filas) {
    sheet.appendRow(fila.map(_celda).toList());
  }

  final bytes = excel.save();
  if (bytes == null) {
    throw Exception('No se pudo generar el archivo Excel');
  }

  return FilePicker.platform.saveFile(
    dialogTitle: 'Guardar reporte',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
    // Con bytes, file_picker escribe el archivo en ambas plataformas:
    // Android lo guarda directo; Windows lo escribe en la ruta elegida.
    bytes: Uint8List.fromList(bytes),
  );
}

/// Mapea un valor crudo de una fila a la celda tipada de Excel. Los números
/// quedan como números (sumables en Excel); el resto, como texto.
CellValue? _celda(Object? v) {
  if (v == null) return null;
  if (v is int) return IntCellValue(v);
  if (v is double) return DoubleCellValue(v);
  if (v is num) return DoubleCellValue(v.toDouble());
  return TextCellValue(v.toString());
}
