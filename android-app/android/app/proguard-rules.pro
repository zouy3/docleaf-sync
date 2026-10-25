# R8 keep rules for the JNI contracts and the Flutter embedding.
#
# The bundled native libraries resolve Java symbols by NAME, so obfuscation
# breaks them at runtime with an UnsatisfiedLinkError -- the build still
# succeeds, which is why these keeps are written out explicitly rather than
# relying on the transitive consumer rules that androidx.annotation ships for
# @Keep. A JNI contract must not depend on an indirect dependency.
#
# The Rust core (libfqapi_core.so) has NO Java JNI surface: Flutter reaches it
# through flutter_rust_bridge over dart:ffi, so no keep rule is needed for it.

# --- generic JNI safety net ---------------------------------------------
# Keeps the class and method name of every native method, which is what the
# JNI naming convention depends on.
-keepclasseswithmembernames class * {
    native <methods>;
}

# --- Flutter plugins registered from MainActivity ------------------------
# These are referenced directly so R8 keeps them alive, but their channel
# handlers are wired at runtime. Keeping the names makes stack traces and
# channel diagnostics readable after obfuscation.
-keep class com.fqapp.fqapp.MainActivity { *; }
-keep class com.fqapp.fqapp.ReaderDevicePlugin { *; }
-keep class com.fqapp.fqapp.ReaderBrightnessSession { *; }

# --- Flutter embedding ---------------------------------------------------
# The embedding is reached from the generated registrant and from native code
# in libflutter.so; keep it whole, as the Flutter release guidance advises.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }

# --- SharedPreferences / JNI Kotlin suspend bridge -----------------------
# Dart's generated JNI bindings resolve suspend methods using descriptors
# containing kotlin/coroutines/Continuation. Keeping plugin method names alone
# still lets R8 rename that parameter type and breaks getAll() on first launch.
-keep,includedescriptorclasses class io.flutter.plugins.sharedpreferences.** { *; }
-keep,includedescriptorclasses class com.github.dart_lang.jni.** { *; }
-keep interface kotlin.coroutines.Continuation { *; }
-keep interface kotlin.coroutines.CoroutineContext { *; }
# package:jni also looks these Kotlin runtime classes/fields up by name.
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }
-keep class kotlin.coroutines.intrinsics.** { *; }

# --- optional Play Core integration -------------------------------------
# Flutter's PlayStoreDeferredComponentManager references the Play Core split
# install API, which is only on the classpath when the app opts into deferred
# components. This app ships a single APK and declares none, so the code path
# is unreachable and the references are safe to silence. Without this, R8 fails
# the build with "Missing classes detected" listing 11
# com.google.android.play.core.* types.
-dontwarn com.google.android.play.core.**

# --- attributes ----------------------------------------------------------
# Signature/annotations are needed by reflection in the AndroidX and Media3
# stack; EnclosingMethod/InnerClasses keep Kotlin lambdas and nested types
# consistent in crash reports.
-keepattributes Signature, InnerClasses, EnclosingMethod, *Annotation*
