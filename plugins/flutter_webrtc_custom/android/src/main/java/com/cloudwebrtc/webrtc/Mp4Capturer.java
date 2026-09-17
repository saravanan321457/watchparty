package com.cloudwebrtc.webrtc;

import android.content.ContentResolver;
import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.util.Log;
import android.view.Surface;
// Mp4AudioExtractor lives in the same package — no import needed
import org.webrtc.CapturerObserver;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.VideoCapturer;
import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;

/**
 * A WebRTC VideoCapturer that decodes a local MP4 file using Android MediaPlayer and
 * feeds decoded frames into WebRTC via SurfaceTextureHelper.
 *
 * Supports:
 *   - Plain file paths:      /storage/emulated/0/Movies/file.mp4
 *   - content:// URIs:       content://media/external/video/media/42
 *   - file:// URIs:          file:///storage/emulated/0/Movies/file.mp4
 *
 * Uses FileDescriptor-based setDataSource so it never needs to copy the file,
 * which means it works correctly with files of any size (including 2 GB+).
 *
 * The static field currentMediaPlayer is used by MainActivity (via MethodChannel
 * "mp4_webrtc") to forward play/pause/seek commands from Flutter.
 */
public class Mp4Capturer implements VideoCapturer {
    private static final String TAG = "Mp4Capturer";

    /** Exposed so MainActivity can call play/pause/seek on it. */
    public static volatile MediaPlayer currentMediaPlayer;

    private SurfaceTextureHelper surfaceTextureHelper;
    private CapturerObserver capturerObserver;
    private Context appContext;
    private MediaPlayer mediaPlayer;
    private boolean listening = false;

    /** The raw string passed from Flutter (file path or content:// URI). */
    private final String rawPath;

    public Mp4Capturer(String rawPath) {
        this.rawPath = rawPath;
    }

    @Override
    public void initialize(SurfaceTextureHelper helper, Context context, CapturerObserver observer) {
        this.surfaceTextureHelper = helper;
        this.capturerObserver = observer;
        this.appContext = context.getApplicationContext();
    }

    @Override
    public void startCapture(int width, int height, int fps) {
        Log.d(TAG, "startCapture: " + rawPath);
        try {
            mediaPlayer = new MediaPlayer();
            currentMediaPlayer = mediaPlayer;

            // ── Start audio extractor in parallel ─────────────────────────────
            // Mp4AudioExtractor opens the same file independently and decodes
            // the audio track to PCM. MethodCallHandlerImpl.AudioBufferCallback
            // drains those samples into WebRTC on each audio tick.
            Mp4AudioExtractor.instance.start(appContext, rawPath);

            // ----------------------------------------------------------------
            // Open the video source via FileDescriptor so we NEVER copy the
            // file, regardless of its size. This correctly handles:
            //   • Plain absolute paths  (/storage/…/file.mp4)
            //   • file:// URIs
            //   • content:// URIs  (MediaStore, SAF, Downloads, etc.)
            // ----------------------------------------------------------------
            setDataSourceSafe(mediaPlayer, rawPath);

            // Register listener BEFORE attaching the Surface so we don't
            // miss the very first frame.
            surfaceTextureHelper.startListening(frame -> {
                capturerObserver.onFrameCaptured(frame);
            });
            listening = true;

            Surface surface = new Surface(surfaceTextureHelper.getSurfaceTexture());
            mediaPlayer.setSurface(surface);

            mediaPlayer.setOnPreparedListener(mp -> {
                int vw = mp.getVideoWidth();
                int vh = mp.getVideoHeight();
                Log.d(TAG, "MediaPlayer prepared — size: " + vw + "x" + vh
                        + "  duration: " + mp.getDuration() + " ms");
                try {
                    surfaceTextureHelper.setTextureSize(vw, vh);
                } catch (Exception e) {
                    Log.w(TAG, "setTextureSize: " + e.getMessage());
                }
                try {
                    surfaceTextureHelper.getSurfaceTexture().setDefaultBufferSize(vw, vh);
                } catch (Exception e) {
                    Log.w(TAG, "setDefaultBufferSize: " + e.getMessage());
                }
                capturerObserver.onCapturerStarted(true);
                // Start then immediately pause so the first frame is rendered
                // (SurfaceTexture needs one frame to size correctly) and so
                // Flutter controls when playback actually begins.
                mp.start();
                mp.pause();
                mp.seekTo(0);
                // Audio extractor stays paused; it will resume when Flutter
                // calls play() via MainActivity's MethodChannel.
                Mp4AudioExtractor.instance.seekTo(0);
            });

            mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                Log.e(TAG, "MediaPlayer error: what=" + what + " extra=" + extra);
                capturerObserver.onCapturerStarted(false);
                return true;
            });

            mediaPlayer.prepareAsync();

        } catch (Exception e) {
            Log.e(TAG, "Failed to open video: " + e.getMessage(), e);
            capturerObserver.onCapturerStarted(false);
        }
    }

    /**
     * Sets the data source on the given MediaPlayer using a FileDescriptor.
     * This avoids any file-size or URI-scheme limitations.
     */
    private void setDataSourceSafe(MediaPlayer mp, String raw) throws IOException {
        // content:// or file:// URI
        if (raw.startsWith("content://") || raw.startsWith("file://")) {
            Uri uri = Uri.parse(raw);
            ContentResolver cr = appContext.getContentResolver();
            try (AssetFileDescriptor afd = cr.openAssetFileDescriptor(uri, "r")) {
                if (afd == null) throw new IOException("ContentResolver returned null for: " + raw);
                mp.setDataSource(afd.getFileDescriptor(), afd.getStartOffset(), afd.getLength());
                Log.d(TAG, "setDataSource via ContentResolver: " + raw);
                return;
            }
        }

        // Plain absolute file path — open as FileDescriptor so we never
        // trigger the internal file-copy path that some Android versions use
        // for large files when you pass a raw String.
        File file = new File(raw);
        if (file.exists()) {
            try (ParcelFileDescriptor pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)) {
                FileDescriptor fd = pfd.getFileDescriptor();
                mp.setDataSource(fd);
                Log.d(TAG, "setDataSource via FileDescriptor: " + raw);
                return;
            }
        }

        // Last resort: try raw string (may fail for large files on some ROMs)
        Log.w(TAG, "setDataSource fallback (raw string): " + raw);
        mp.setDataSource(raw);
    }

    @Override
    public void stopCapture() throws InterruptedException {
        Log.d(TAG, "stopCapture");
        Mp4AudioExtractor.instance.stop();
        if (mediaPlayer != null) {
            try { mediaPlayer.stop(); } catch (Exception ignored) {}
            mediaPlayer.release();
            mediaPlayer = null;
            currentMediaPlayer = null;
        }
        if (listening && surfaceTextureHelper != null) {
            surfaceTextureHelper.stopListening();
            listening = false;
        }
    }

    @Override public void changeCaptureFormat(int width, int height, int fps) {}
    @Override public void dispose() {
        try { stopCapture(); } catch (InterruptedException ignored) {}
    }
    @Override public boolean isScreencast() { return false; }
}
