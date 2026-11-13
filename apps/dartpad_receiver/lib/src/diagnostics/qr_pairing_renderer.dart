import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:qr/qr.dart';

/// Generates scannable QR Codes (both terminal Unicode half-block matrices and
/// 2D boolean matrices for GUI rendering) from a [PairingPayload].
class QrPairingRenderer {
  const QrPairingRenderer._();

  /// Generates a 2D boolean matrix (`true` = dark module, `false` = light module)
  /// for rendering in a GUI or terminal.
  static List<List<bool>> generateMatrix(PairingPayload payload) {
    final qrCode = QrCode.fromData(
      data: payload.toQrUriString(),
      errorCorrectLevel: QrErrorCorrectLevel.L,
    );
    final qrImage = QrImage(qrCode);
    final count = qrImage.moduleCount;

    return List<List<bool>>.generate(
      count,
      (row) => List<bool>.generate(
        count,
        (col) => qrImage.isDark(row, col),
        growable: false,
      ),
      growable: false,
    );
  }

  /// Renders a compact, scannable QR code using Unicode half-block characters
  /// (`▀`, `▄`, `█`, ` `) so any phone camera can scan it directly from the
  /// Windows Receiver console/terminal window.
  static String renderTerminalQr(PairingPayload payload, {int quietZone = 2}) {
    final matrix = generateMatrix(payload);
    final size = matrix.length;
    final totalSize = size + quietZone * 2;

    bool isDarkWithBorder(int r, int c) {
      final mr = r - quietZone;
      final mc = c - quietZone;
      if (mr < 0 || mr >= size || mc < 0 || mc >= size) {
        return false; // White quiet zone border required by QR scanners
      }
      return matrix[mr][mc];
    }

    final buf = StringBuffer();
    for (var r = 0; r < totalSize; r += 2) {
      buf.write('  ');
      for (var c = 0; c < totalSize; c++) {
        final topDark = isDarkWithBorder(r, c);
        final bottomDark = (r + 1 < totalSize) ? isDarkWithBorder(r + 1, c) : false;

        // Invert for dark terminal backgrounds (light blocks = quiet zone / light modules)
        if (!topDark && !bottomDark) {
          buf.write('█');
        } else if (!topDark && bottomDark) {
          buf.write('▀');
        } else if (topDark && !bottomDark) {
          buf.write('▄');
        } else {
          buf.write(' ');
        }
      }
      buf.writeln();
    }
    return buf.toString();
  }
}
