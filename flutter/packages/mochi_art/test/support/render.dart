// Test helpers: render art offscreen and write PNG sheets laid out like the Swift
// `--render-snapshots` / `--render-strips` sheets, for side-by-side comparison.
//
// PNGs go to $MOCHI_ART_OUT when set, else to test/out (git-ignored).

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/mochi_art.dart';

/// Where comparison PNGs are written.
Directory outputDirectory() {
  final path = Platform.environment['MOCHI_ART_OUT'] ?? 'test/out';
  return Directory(path)..createSync(recursive: true);
}

/// The poses exported from Swift by flutter/tools/pose_export.
Map<String, Object?> referencePoses() {
  final file = File('test/fixtures/reference_poses.json');
  return (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
}

List<Map<String, Object?>> referenceList(String key) =>
    ((referencePoses()[key] as List?) ?? const []).map((e) => (e as Map).cast<String, Object?>()).toList();

bool _fontsLoaded = false;

/// Loads SF Pro Rounded (on a Mac) so the few glyphs the art draws, and the sheet labels,
/// look like the Swift renders instead of the test font's boxes.
Future<void> loadArtFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  const path = '/System/Library/Fonts/SFNSRounded.ttf';
  final file = File(path);
  if (!file.existsSync()) return;
  final bytes = file.readAsBytesSync();
  final loader = FontLoader('MochiRounded')..addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
  await loader.load();
  MochiArtText.family = 'MochiRounded';
  MochiArtText.variableWeight = true;
}

/// Draws into a fresh canvas of `size` points at `scale` pixels per point.
Future<ui.Image> renderImage(Size size, double scale, void Function(Canvas canvas) draw) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);
  draw(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage((size.width * scale).ceil(), (size.height * scale).ceil());
  picture.dispose();
  return image;
}

Future<File> writePng(String name, ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('${outputDirectory().path}/$name');
  file.writeAsBytesSync(data!.buffer.asUint8List());
  return file;
}

/// One cell of a sheet: art drawn into `size` (origin at the cell's top left), with a label under it.
class Cell {
  Cell(this.label, this.size, this.draw, {this.background, this.clip = false});

  final String label;
  final Size size;
  final void Function(GContext g, Size size) draw;
  final Color? background;

  /// Clip the art to the cell (SwiftUI `.clipped()`); a Canvas draws outside its frame otherwise.
  final bool clip;
}

/// Draws a label centred at `center`.
void drawLabel(Canvas canvas, String text, Offset center, {double size = 9, Color color = const Color(0x99000000), bool left = false}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: size,
        fontFamily: MochiArtText.family,
        fontVariations: MochiArtText.variableWeight ? [const FontVariation('wght', 500)] : null,
        color: color,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final x = left ? center.dx : center.dx - painter.width / 2;
  painter.paint(canvas, Offset(x, center.dy - painter.height / 2));
  painter.dispose();
}

/// A grid of cells (rows of `columns`), each with an optional label below, like the Swift sheets.
Future<File> writeSheet(
  String name,
  List<Cell> cells, {
  int columns = 8,
  double scale = 2,
  double padding = 8,
  double spacing = 4,
  double labelHeight = 12,
  Color background = const Color(0xFFFBF4EC),
}) async => writePng(
  name,
  await sheetImage(
    cells,
    columns: columns,
    scale: scale,
    padding: padding,
    spacing: spacing,
    labelHeight: labelHeight,
    background: background,
  ),
);

/// The image of a sheet (see [writeSheet]); golden tests compare these without labels.
Future<ui.Image> sheetImage(
  List<Cell> cells, {
  int columns = 8,
  double scale = 2,
  double padding = 8,
  double spacing = 4,
  double labelHeight = 12,
  Color background = const Color(0xFFFBF4EC),
}) async {
  final rows = <List<Cell>>[];
  for (var i = 0; i < cells.length; i += columns) {
    rows.add(cells.sublist(i, i + columns > cells.length ? cells.length : i + columns));
  }
  final rowHeights = rows.map((r) => r.map((c) => c.size.height).reduce((a, b) => a > b ? a : b) + labelHeight).toList();
  final rowWidths = rows.map((r) => r.map((c) => c.size.width).reduce((a, b) => a + b) + spacing * (r.length - 1)).toList();
  final width = rowWidths.reduce((a, b) => a > b ? a : b) + padding * 2;
  final height = rowHeights.reduce((a, b) => a + b) + spacing * (rows.length - 1) + padding * 2;
  final size = Size(width, height);
  final image = await renderImage(size, scale, (canvas) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    var y = padding;
    for (var r = 0; r < rows.length; r++) {
      var x = padding;
      for (final cell in rows[r]) {
        canvas.save();
        canvas.translate(x, y);
        if (cell.clip || cell.background != null) canvas.clipRect(Offset.zero & cell.size);
        if (cell.background != null) canvas.drawRect(Offset.zero & cell.size, Paint()..color = cell.background!);
        cell.draw(GContext(canvas), cell.size);
        canvas.restore();
        if (labelHeight > 0 && cell.label.isNotEmpty) {
          drawLabel(canvas, cell.label, Offset(x + cell.size.width / 2, y + cell.size.height + labelHeight / 2));
        }
        x += cell.size.width + spacing;
      }
      y += rowHeights[r] + spacing;
    }
  });
  return image;
}

/// One row of a strip sheet: a title, then frames side by side, each with a caption under it.
class StripRow {
  StripRow(this.title, this.frames);

  final String title;
  final List<Cell> frames;
}

/// Rows of animation frames like `AnimationStrips.petSheet` (title column, frames, time captions).
Future<ui.Image> stripImage(
  List<StripRow> rows, {
  double titleWidth = 84,
  double captionHeight = 9,
  double rowSpacing = 2,
  double padding = 6,
  double scale = 1.5,
  Color background = const Color(0xFFFBF4EC),
}) async {
  final rowHeights = rows.map((r) => r.frames.map((c) => c.size.height).reduce((a, b) => a > b ? a : b) + captionHeight).toList();
  final rowWidths = rows.map((r) => titleWidth + r.frames.map((c) => c.size.width).reduce((a, b) => a + b)).toList();
  final size = Size(
    rowWidths.reduce((a, b) => a > b ? a : b) + padding * 2,
    rowHeights.reduce((a, b) => a + b) + rowSpacing * (rows.length - 1) + padding * 2,
  );
  return renderImage(size, scale, (canvas) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    var y = padding;
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      if (titleWidth > 0) {
        drawLabel(canvas, row.title, Offset(padding, y + rowHeights[r] / 2), size: 9, color: const Color(0xFF000000), left: true);
      }
      var x = padding + titleWidth;
      for (final cell in row.frames) {
        canvas.save();
        canvas.translate(x, y);
        canvas.clipRect(Offset.zero & cell.size);
        if (cell.background != null) canvas.drawRect(Offset.zero & cell.size, Paint()..color = cell.background!);
        cell.draw(GContext(canvas), cell.size);
        canvas.restore();
        if (captionHeight > 0 && cell.label.isNotEmpty) {
          drawLabel(canvas, cell.label, Offset(x + cell.size.width / 2, y + cell.size.height + captionHeight / 2), size: 7);
        }
        x += cell.size.width;
      }
      y += rowHeights[r] + rowSpacing;
    }
  });
}

/// Skips tests that only write PNGs for eyeballing unless MOCHI_ART_OUT names where they go.
String? get pngSkip => Platform.environment['MOCHI_ART_OUT'] == null ? 'set MOCHI_ART_OUT=<dir> to write the comparison PNGs' : null;
