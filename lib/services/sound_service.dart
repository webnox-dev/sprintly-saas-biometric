import 'dart:typed_data';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';

class SoundService {
  final AudioPlayer _audioPlayer = AudioPlayer();

  SoundService() {
    _audioPlayer.setReleaseMode(ReleaseMode.stop); // Reusable
  }

  /// Plays a generated beep sound (PCM 16-bit, 44.1kHz, Mono)
  Future<void> playErrorBeep() async {
    try {
      // 1. Generate a simple Beep Tone (Sine Wave)
      // Duration: 300ms, Frequency: 800Hz (Typical Error Beep)
      final Uint8List wavData = _generateWav(300, 800);

      // 2. Play from memory
      await _audioPlayer.play(BytesSource(wavData));

      // Wait for it to mostly finish before returning to allow voice to effectively follow
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      print('❌ Error playing beep: $e');
    }
  }

  /// Plays a generated success beep sound
  Future<void> playSuccess() async {
    try {
      // 1. Generate a higher-pitched double Beep Tone
      // Duration: 150ms each, Frequency: 1200Hz then 1500Hz
      final Uint8List wavData1 = _generateWav(100, 1200);
      final Uint8List wavData2 = _generateWav(150, 1500);

      await _audioPlayer.play(BytesSource(wavData1));
      await Future.delayed(const Duration(milliseconds: 120));
      await _audioPlayer.play(BytesSource(wavData2));
      await Future.delayed(const Duration(milliseconds: 150));
    } catch (e) {
      print('❌ Error playing success beep: $e');
    }
  }

  /// Generates a valid WAV file in memory with a sine wave tone
  Uint8List _generateWav(int durationMs, int frequency) {
    const int sampleRate = 44100;
    const int numChannels = 1;
    final int numSamples = (sampleRate * (durationMs / 1000)).toInt();
    final int byteRate = sampleRate * numChannels * 2; // 16-bit = 2 bytes
    final int blockAlign = numChannels * 2;
    final int dataSize = numSamples * blockAlign;
    final int fileSize = 36 + dataSize;

    final ByteData header = ByteData(44);

    // RIFF chunk
    _writeString(header, 0, 'RIFF');
    header.setUint32(4, fileSize, Endian.little);
    _writeString(header, 8, 'WAVE');

    // fmt chunk
    _writeString(header, 12, 'fmt ');
    header.setUint32(16, 16, Endian.little); // Subchunk1Size
    header.setUint16(20, 1, Endian.little); // AudioFormat (1 = PCM)
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, 16, Endian.little); // BitsPerSample

    // data chunk
    _writeString(header, 36, 'data');
    header.setUint32(40, dataSize, Endian.little);

    // Generate Audio Samples (Sine Wave)
    final Int16List samples = Int16List(numSamples);
    const double amplitude = 32000; // Max 32767

    for (int i = 0; i < numSamples; i++) {
      // Sine wave formula: A * sin(2 * pi * f * t)
      final double t = i / sampleRate;
      final double theta = 2 * pi * frequency * t;
      samples[i] = (amplitude * sin(theta)).toInt();
    }

    // Combine Header + Data
    final Uint8List wavBytes = Uint8List(44 + (numSamples * 2));
    wavBytes.setRange(0, 44, header.buffer.asUint8List());
    wavBytes.setRange(44, wavBytes.length, samples.buffer.asUint8List());

    return wavBytes;
  }

  void _writeString(ByteData data, int offset, String value) {
    for (int i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  void dispose() {
    _audioPlayer.dispose();
  }
}
