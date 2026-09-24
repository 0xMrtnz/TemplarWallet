# R8 rules for the release APK. Flutter already supplies
# proguard-android-optimize.txt and flutter_proguard_rules.pro; this file is
# appended to them (see build.gradle.kts).

# ML Kit — the barcode engine behind mobile_scanner, and the reason camera QR
# scanning was dead in every release APK up to 0.1.0-alpha.8.
#
# ML Kit boots from a ContentProvider (MlKitInitProvider) that reads the
# ComponentRegistrar class names out of the merged manifest's <meta-data> and
# instantiates each one by reflection. R8 sees no code path to those no-arg
# constructors and deletes them (mapping/release/usage.txt listed
# CommonComponentRegistrar.<init>() and BarcodeRegistrar.<init>() as removed),
# so discovery throws NoSuchMethodException at startup, the barcode client is
# never registered, and the first scanner.start() dies with
#   NullPointerException … on a null object reference
# on dev.steenbakker.mobile_scanner/scanner/method. The scanner then renders
# its errorBuilder ("Camera unavailable") — with the camera permission granted
# and the camera itself perfectly fine.
#
# mobile_scanner ships a consumer rule for this, but it reads
# `-keep class com.google.mlkit.* { *; }`: one asterisk, which matches only
# the classes sitting directly in com.google.mlkit and none of the registrars,
# which live in com.google.mlkit.*.internal. Two asterisks here.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google.android.libraries.barhopper.** { *; }

# Belt and braces for the same reflective-discovery pattern: whatever else
# registers a component this way keeps the constructor discovery calls.
-keep class * implements com.google.firebase.components.ComponentRegistrar {
    <init>();
}
