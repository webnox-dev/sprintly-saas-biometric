import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceDetectionService {
  late FaceDetector _faceDetector;
  bool _isProcessing = false;
  DateTime _lastProcessed = DateTime.now();

  FaceDetectionService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: true,
        enableClassification: true,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.1,
      ),
    );
  }

  Future<List<Face>> detectFaces(
    CameraImage cameraImage,
    CameraDescription camera,
  ) async {
    if (_isProcessing) return [];

    if (DateTime.now().difference(_lastProcessed).inMilliseconds < 300) {
      return [];
    }

    _isProcessing = true;
    _lastProcessed = DateTime.now();

    try {
      final inputImage = _convert(cameraImage, camera);
      if (inputImage == null) return [];

      return await _faceDetector.processImage(inputImage);
    } finally {
      _isProcessing = false;
    }
  }

  Future<List<Face>> processImage(InputImage inputImage) async {
    return await _faceDetector.processImage(inputImage);
  }

  InputImage? _convert(CameraImage image, CameraDescription camera) {
    final rotation = _getRotation(camera);
    final format = InputImageFormatValue.fromRawValue(image.format.raw);

    if (rotation == null || format == null) return null;

    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  InputImageRotation? _getRotation(CameraDescription camera) {
    final sensor = camera.sensorOrientation;

    if (camera.lensDirection == CameraLensDirection.front) {
      switch (sensor) {
        case 90:
          return InputImageRotation.rotation270deg;
        case 270:
          return InputImageRotation.rotation90deg;
        default:
          return InputImageRotation.rotation0deg;
      }
    }

    switch (sensor) {
      case 0:
        return InputImageRotation.rotation0deg;
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return null;
    }
  }

  bool isFaceQualityGood(Face face) {
    final rotY = face.headEulerAngleY ?? 0;
    final rotZ = face.headEulerAngleZ ?? 0;

    if (rotY.abs() > 30 || rotZ.abs() > 30) return false;

    final box = face.boundingBox;
    if (box.width < 100 || box.height < 100) return false;

    return true;
  }

  void dispose() {
    _faceDetector.close();
  }
}
