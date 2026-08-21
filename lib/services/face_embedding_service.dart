import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class FaceEmbeddingService {
  Interpreter? _interpreter;

  static const int _inputSize = 112;
  static const int _embeddingSize = 192;
  static const double _threshold = 0.65;

  Future<void> init() async {
    _interpreter = await Interpreter.fromAsset(
      'assets/models/mobilefacenet.tflite',
    );
  }

  Future<List<double>> getEmbedding(
    Uint8List bytes, {
    Map<String, int>? faceRect,
    bool isFrontCamera = false,
    double? leftEyeX,
    double? leftEyeY,
    double? rightEyeX,
    double? rightEyeY,
  }) async {
    final image = img.decodeImage(bytes)!;

    img.Image face = _cropFace(image, faceRect);

    if (isFrontCamera) {
      face = img.flipHorizontal(face);
    }

    face = _alignFace(face, leftEyeX, leftEyeY, rightEyeX, rightEyeY);

    final resized = img.copyResize(face, width: 112, height: 112);

    final input = _input(resized);
    final output = List.generate(1, (_) => List.filled(192, 0.0));

    _interpreter!.run(input, output);

    return _normalize(output[0]);
  }

  List<double> average(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return [];
    final size = embeddings[0].length;
    final avg = List.filled(size, 0.0);

    for (final emb in embeddings) {
      for (int i = 0; i < size; i++) {
        avg[i] += emb[i];
      }
    }

    return _normalize(avg.map((v) => v / embeddings.length).toList());
  }

  Future<List<double>> getAveragedEmbedding(
    List<Uint8List> images, {
    List<Map<String, int>>? faceRects,
  }) async {
    final embeddings = <List<double>>[];
    for (int i = 0; i < images.length; i++) {
      final rect = (faceRects != null && faceRects.length > i)
          ? faceRects[i]
          : null;
      final emb = await getEmbedding(images[i], faceRect: rect);
      embeddings.add(emb);
    }
    return average(embeddings);
  }

  img.Image _cropFace(img.Image image, Map<String, int>? rect) {
    if (rect == null) return image;

    final x = rect['x']!;
    final y = rect['y']!;
    final w = rect['width']!;
    final h = rect['height']!;

    final cx = x + w / 2;
    final cy = y + h / 2;

    final size = (max(w, h) * 1.5).toInt();
    final half = size ~/ 2;

    final cropX = (cx - half).toInt().clamp(0, image.width - 1);
    final cropY = (cy - half).toInt().clamp(0, image.height - 1);

    final cropW = min(size, image.width - cropX);
    final cropH = min(size, image.height - cropY);

    return img.copyCrop(image, x: cropX, y: cropY, width: cropW, height: cropH);
  }

  img.Image _alignFace(
    img.Image image,
    double? lx,
    double? ly,
    double? rx,
    double? ry,
  ) {
    if (lx == null || ly == null || rx == null || ry == null) return image;

    final dx = rx - lx;
    final dy = ry - ly;

    final angle = atan2(dy, dx);

    return img.copyRotate(image, angle: -angle * 180 / pi);
  }

  List<List<List<List<double>>>> _input(img.Image image) {
    return [
      List.generate(_inputSize, (y) {
        return List.generate(_inputSize, (x) {
          final p = image.getPixel(x, y);
          return [(p.r / 127.5) - 1, (p.g / 127.5) - 1, (p.b / 127.5) - 1];
        });
      }),
    ];
  }

  List<double> _normalize(List<double> emb) {
    final norm = sqrt(emb.fold(0.0, (s, e) => s + e * e));
    return emb.map((e) => e / norm).toList();
  }

  double cosine(List<double> a, List<double> b) {
    double dot = 0, na = 0, nb = 0;

    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }

    return dot / (sqrt(na) * sqrt(nb));
  }

  double cosineSimilarity(List<double> a, List<double> b) => cosine(a, b);

  void dispose() {
    _interpreter?.close();
  }
}
