# Picked up by Flutter's Gradle plugin for release builds; there is nothing to
# wire in build.gradle.kts.

# The text recognition plugin names the recogniser options of every script it
# can drive. Only the Latin model is bundled, so the rest are not on the
# classpath, and R8 fails the build over references that are never reached.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# PdfWriter sits in android.print to reach the package-private constructors of
# the print callbacks. Renamed into another package it would throw
# IllegalAccessError the first time HTML to PDF ran.
-keep class android.print.PdfWriter { *; }
