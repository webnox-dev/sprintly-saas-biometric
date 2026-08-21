import 'dart:math';

class EmployeeEmbedding {
  final String id;
  final String name;
  final List<List<double>> embeddings;

  EmployeeEmbedding({
    required this.id,
    required this.name,
    required this.embeddings,
  });
}

class FaceMatcher {
  static const double threshold = 0.65;

  FaceMatchResult? match(
    List<double> input,
    List<EmployeeEmbedding> employees,
  ) {
    double bestScore = 0;
    EmployeeEmbedding? best;

    for (final emp in employees) {
      for (final emb in emp.embeddings) {
        final score = _cosine(input, emb);

        if (score > bestScore) {
          bestScore = score;
          best = emp;
        }
      }
    }

    if (best != null && bestScore > threshold) {
      return FaceMatchResult(
        id: best.id,
        name: best.name,
        confidence: bestScore,
      );
    }

    return null;
  }

  double _cosine(List<double> a, List<double> b) {
    double dot = 0, na = 0, nb = 0;

    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }

    return dot / (sqrt(na) * sqrt(nb));
  }
}

class FaceMatchResult {
  final String id;
  final String name;
  final double confidence;

  FaceMatchResult({
    required this.id,
    required this.name,
    required this.confidence,
  });
}
