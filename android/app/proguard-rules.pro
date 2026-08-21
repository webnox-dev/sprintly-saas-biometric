# TensorFlow Lite rules
-keep class org.tensorflow.lite.gpu.GpuDelegateFactory$Options { *; }
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options

# Google ML Kit rules
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }

# Prevent R8 from stripping away TFLite JNI methods
-keep class org.tensorflow.lite.** { *; }
-keepattributes Signature
-keepattributes *Annotation*

# Mantra MorfinAuth SDK rules
-keep class com.mantra.morfinauth.** { *; }
-keep interface com.mantra.morfinauth.** { *; }
-dontwarn com.mantra.morfinauth.**

