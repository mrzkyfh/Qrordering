# Pertahankan metadata yang dipakai Gson pada model notifikasi dan sejumlah
# plugin Flutter, tanpa mematikan optimisasi/obfuscation untuk seluruh app.
-keepattributes Signature,*Annotation*,InnerClasses,EnclosingMethod

# SDK printer merupakan JAR vendor tanpa consumer ProGuard rules. API-nya
# dipanggil dari plugin dan sebagian modelnya memakai nama class/enum runtime.
-keep class com.gprinter.** { *; }
-keep class com.example.bluetooth_print_plus.bluetooth_print_plus.** { *; }

# Barcode helper opsional pada SDK printer vendor tidak ikut dipaketkan oleh
# plugin. Kode printer menangani ketidakhadirannya saat fitur tersebut tidak
# digunakan; jangan biarkan referensi optional ini menggagalkan R8 release.
-dontwarn com.gainscha.jzint.**
