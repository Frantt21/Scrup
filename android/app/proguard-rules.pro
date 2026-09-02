# youtubedl-android — keep all public API and JNI classes
-keep class com.yausername.youtubedl_android.** { *; }
-keep class com.yausername.youtubedl_android.** { *; }
-dontwarn com.yausername.youtubedl_android.**

# Python / CPython JNI bridge
-keep class org.python.** { *; }
-dontwarn org.python.**

# FFmpeg JNI
-keep class com.yausername.youtubedl_android.ffmpeg.** { *; }
-dontwarn com.yausername.youtubedl_android.ffmpeg.**

# QuickJS
-keep class com.yausername.youtubedl_android.quickjs.** { *; }
-dontwarn com.yausername.youtubedl_android.quickjs.**

# aria2c
-keep class com.yausername.youtubedl_android.aria2c.** { *; }
-dontwarn com.yausername.youtubedl_android.aria2c.**

# Drift / SQLite (database)
-keep class drift.** { *; }
-keep class orgsqlite.** { *; }
-keep class org.sqlite.** { *; }
