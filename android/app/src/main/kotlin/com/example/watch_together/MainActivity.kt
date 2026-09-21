package com.example.watch_together

import com.cloudwebrtc.webrtc.Mp4Capturer
import com.cloudwebrtc.webrtc.Mp4AudioExtractor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mp4_webrtc")
            .setMethodCallHandler { call, result ->
                // Grab the FakePlayer exposed by the new unified Mp4Capturer
                val player: Mp4Capturer.FakePlayer? = try {
                    val cls = Class.forName("com.cloudwebrtc.webrtc.Mp4Capturer")
                    cls.getField("currentMediaPlayer").get(null) as? Mp4Capturer.FakePlayer
                } catch (e: Exception) {
                    null
                }

                if (player != null) {
                    try {
                        when (call.method) {
                            "play"  -> { player.start();  result.success(null) }
                            "pause" -> { player.pause();  result.success(null) }
                            "seek"  -> {
                                val ms = call.argument<Int>("position") ?: 0
                                player.seekTo(ms)
                                result.success(null)
                            }
                            "getPosition" -> result.success(player.currentPosition())
                            "getDuration" -> result.success(player.duration())
                            else -> result.notImplemented()
                        }
                    } catch (e: Exception) {
                        if (call.method == "getPosition" || call.method == "getDuration") {
                            result.success(0)
                        } else {
                            result.success(null)
                        }
                    }
                } else {
                    if (call.method == "getPosition" || call.method == "getDuration") {
                        result.success(0)
                    } else {
                        result.success(null)
                    }
                }
            }
    }
}
