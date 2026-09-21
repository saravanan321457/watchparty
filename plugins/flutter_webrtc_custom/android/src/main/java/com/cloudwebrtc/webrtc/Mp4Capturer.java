package com.cloudwebrtc.webrtc;

import android.content.ContentResolver;
import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.util.Log;
import android.view.Surface;

import org.webrtc.CapturerObserver;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.VideoCapturer;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * UNIFIED Mp4Capturer — reads VIDEO + AUDIO from a single MediaExtractor.
 *
 * Video → MediaCodec (hardware accelerated) → Surface → SurfaceTextureHelper → WebRTC VideoTrack
 * Audio → MediaCodec → PCM → Mp4AudioExtractor queue → WebRTC AudioBufferCallback
 *
 * A single threaded demux loop reads interleaved samples by PTS, feeding each
 * codec in order. This guarantees perfect A/V sync at the source — no drift.
 */
public class Mp4Capturer implements VideoCapturer {
    private static final String TAG = "Mp4Capturer";

    // Fake MediaPlayer-like position tracking for Flutter controls
    public static volatile FakePlayer currentMediaPlayer;

    private SurfaceTextureHelper surfaceTextureHelper;
    private CapturerObserver capturerObserver;
    private Context appContext;
    private Surface decodeSurface;
    private boolean listening = false;

    private final String rawPath;

    // Playback state
    private final AtomicBoolean active = new AtomicBoolean(false);
    private final AtomicBoolean paused = new AtomicBoolean(true);
    private final Object pauseLock = new Object();
    private volatile long pendingSeekMs = -1;
    private volatile long positionUs = 0;
    private volatile long durationUs = 0;

    // Decode thread
    private Thread demuxThread;

    public Mp4Capturer(String rawPath) {
        this.rawPath = rawPath;
    }

    // ── VideoCapturer interface ───────────────────────────────────────────

    @Override
    public void initialize(SurfaceTextureHelper helper, Context context, CapturerObserver observer) {
        this.surfaceTextureHelper = helper;
        this.capturerObserver     = observer;
        this.appContext           = context.getApplicationContext();
    }

    @Override
    public void startCapture(int width, int height, int fps) {
        Log.d(TAG, "startCapture: " + rawPath);

        // Register frame listener so WebRTC gets video frames from the Surface
        surfaceTextureHelper.startListening(frame -> capturerObserver.onFrameCaptured(frame));
        listening = true;

        decodeSurface = new Surface(surfaceTextureHelper.getSurfaceTexture());

        // Start Mp4AudioExtractor (it will be fed by our demux loop, not by its own decoder)
        // We configure it as a passthrough queue — our demux loop pushes PCM directly.
        Mp4AudioExtractor.instance.start(appContext, rawPath);

        // Expose fake player for Flutter controls
        FakePlayer player = new FakePlayer();
        currentMediaPlayer = player;

        // Start demux thread
        active.set(true);
        paused.set(true); // starts paused; Flutter calls play() explicitly
        pendingSeekMs = 0;

        demuxThread = new Thread(this::demuxLoop, "Mp4Demux");
        demuxThread.setDaemon(true);
        demuxThread.start();

        capturerObserver.onCapturerStarted(true);
    }

    @Override
    public void stopCapture() throws InterruptedException {
        Log.d(TAG, "stopCapture");
        active.set(false);
        paused.set(false);
        synchronized (pauseLock) { pauseLock.notifyAll(); }
        Mp4AudioExtractor.instance.stop();
        if (demuxThread != null) {
            demuxThread.interrupt();
            demuxThread.join(1000);
            demuxThread = null;
        }
        if (listening && surfaceTextureHelper != null) {
            surfaceTextureHelper.stopListening();
            listening = false;
        }
        if (decodeSurface != null) {
            decodeSurface.release();
            decodeSurface = null;
        }
        currentMediaPlayer = null;
    }

    @Override public void changeCaptureFormat(int w, int h, int fps) {}
    @Override public void dispose() { try { stopCapture(); } catch (InterruptedException ignored) {} }
    @Override public boolean isScreencast() { return false; }

    // ── Play controls (called from FakePlayer / MainActivity) ────────────

    public void play() {
        paused.set(false);
        Mp4AudioExtractor.instance.resume();
        synchronized (pauseLock) { pauseLock.notifyAll(); }
    }

    public void pause() {
        paused.set(true);
        Mp4AudioExtractor.instance.pause();
    }

    public void seekTo(long ms) {
        pendingSeekMs = ms;
        Mp4AudioExtractor.instance.seekTo(ms);
        synchronized (pauseLock) { pauseLock.notifyAll(); }
    }

    public int getCurrentPosition() { return (int)(positionUs / 1000); }
    public int getDuration()        { return (int)(durationUs / 1000); }

    // ── FakePlayer shim (maintains backward compat with MainActivity) ────

    public class FakePlayer {
        public void start()           { play(); }
        public void pause()           { Mp4Capturer.this.pause(); }
        public void seekTo(int ms)    { Mp4Capturer.this.seekTo(ms); }
        public int  currentPosition() { return getCurrentPosition(); }
        public int  duration()        { return getDuration(); }
    }

    // ── Demux loop ───────────────────────────────────────────────────────

    private void demuxLoop() {
        while (active.get()) {
            // Wait while paused
            synchronized (pauseLock) {
                while (active.get() && paused.get() && pendingSeekMs < 0) {
                    try { pauseLock.wait(100); } catch (InterruptedException ignored) {}
                }
            }
            if (!active.get()) break;
            try {
                runDemux();
            } catch (Exception e) {
                Log.e(TAG, "Demux error: " + e.getMessage(), e);
                try { Thread.sleep(500); } catch (InterruptedException ignored) {}
            }
        }
        Log.d(TAG, "demuxLoop exited");
    }

    private void runDemux() throws IOException {
        MediaExtractor extractor = new MediaExtractor();
        try {
            openExtractor(extractor, rawPath);

            // Find video and audio tracks
            int         videoTrack  = -1, audioTrack = -1;
            MediaFormat videoFormat = null, audioFormat = null;

            for (int i = 0; i < extractor.getTrackCount(); i++) {
                MediaFormat fmt  = extractor.getTrackFormat(i);
                String      mime = fmt.getString(MediaFormat.KEY_MIME);
                if (mime == null) continue;
                if (mime.startsWith("video/") && videoTrack < 0) {
                    videoTrack  = i;
                    videoFormat = fmt;
                }
                if (mime.startsWith("audio/") && audioTrack < 0) {
                    audioTrack  = i;
                    audioFormat = fmt;
                }
            }

            if (videoTrack < 0) {
                Log.e(TAG, "No video track found");
                active.set(false);
                return;
            }

            extractor.selectTrack(videoTrack);
            if (audioTrack >= 0) extractor.selectTrack(audioTrack);

            // Duration
            if (videoFormat.containsKey(MediaFormat.KEY_DURATION)) {
                durationUs = videoFormat.getLong(MediaFormat.KEY_DURATION);
            }

            // Configure video decoder → Surface (hardware accelerated, full quality)
            String     videoMime    = videoFormat.getString(MediaFormat.KEY_MIME);
            int        vw           = videoFormat.containsKey(MediaFormat.KEY_WIDTH)  ? videoFormat.getInteger(MediaFormat.KEY_WIDTH)  : 1280;
            int        vh           = videoFormat.containsKey(MediaFormat.KEY_HEIGHT) ? videoFormat.getInteger(MediaFormat.KEY_HEIGHT) : 720;

            // Tell WebRTC the correct video dimensions
            try { surfaceTextureHelper.setTextureSize(vw, vh); } catch (Exception ignored) {}
            try { surfaceTextureHelper.getSurfaceTexture().setDefaultBufferSize(vw, vh); } catch (Exception ignored) {}

            MediaCodec videoCodec = MediaCodec.createDecoderByType(videoMime);
            videoCodec.configure(videoFormat, decodeSurface, null, 0);
            videoCodec.start();
            Log.i(TAG, "Video decoder: " + videoMime + " " + vw + "x" + vh);

            // Configure audio decoder → PCM queue in Mp4AudioExtractor
            MediaCodec audioCodec = null;
            if (audioFormat != null) {
                String audioMime = audioFormat.getString(MediaFormat.KEY_MIME);
                audioCodec = MediaCodec.createDecoderByType(audioMime);
                audioCodec.configure(audioFormat, null, null, 0);
                audioCodec.start();
                Log.i(TAG, "Audio decoder: " + audioMime);
                // Notify extractor about native format
                int sr  = audioFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)   ? audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)   : 44100;
                int ch  = audioFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT) ? audioFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT) : 2;
                Mp4AudioExtractor.instance.setNativeFormat(sr, ch);
            }

            // Handle initial seek
            long sk = pendingSeekMs;
            if (sk >= 0) {
                extractor.seekTo(sk * 1000L, MediaExtractor.SEEK_TO_CLOSEST_SYNC);
                pendingSeekMs = -1;
                positionUs    = sk * 1000L;
                Mp4AudioExtractor.instance.clearQueue();
                if (audioCodec != null) audioCodec.flush();
                videoCodec.flush();
            }

            MediaCodec.BufferInfo info    = new MediaCodec.BufferInfo();
            boolean videoInputDone  = false;
            boolean audioInputDone  = false;
            boolean videoOutputDone = false;
            boolean audioOutputDone = (audioCodec == null);

            final long TIMEOUT_US = 5_000L;

            while (active.get() && !(videoOutputDone && audioOutputDone)) {

                // Handle pause
                if (paused.get() && pendingSeekMs < 0) {
                    // Drain video output so screen doesn't freeze mid-frame
                    drainVideoOutput(videoCodec, info, TIMEOUT_US, true);
                    synchronized (pauseLock) {
                        while (active.get() && paused.get() && pendingSeekMs < 0) {
                            try { pauseLock.wait(100); } catch (InterruptedException ignored) {}
                        }
                    }
                }
                if (!active.get()) break;

                // Handle seek
                long seekMs = pendingSeekMs;
                if (seekMs >= 0) {
                    videoCodec.flush();
                    if (audioCodec != null) audioCodec.flush();
                    extractor.seekTo(seekMs * 1000L, MediaExtractor.SEEK_TO_CLOSEST_SYNC);
                    pendingSeekMs  = -1;
                    positionUs     = seekMs * 1000L;
                    videoInputDone = false;
                    audioInputDone = false;
                    Mp4AudioExtractor.instance.clearQueue();
                    continue;
                }

                // ── Feed input ────────────────────────────────────────────
                if (!videoInputDone || (audioCodec != null && !audioInputDone)) {
                    int trackIdx = extractor.getSampleTrackIndex();
                    if (trackIdx < 0) {
                        // EOS on all tracks
                        if (!videoInputDone) {
                            int inIdx = videoCodec.dequeueInputBuffer(TIMEOUT_US);
                            if (inIdx >= 0) {
                                videoCodec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                                videoInputDone = true;
                            }
                        }
                        if (audioCodec != null && !audioInputDone) {
                            int inIdx = audioCodec.dequeueInputBuffer(TIMEOUT_US);
                            if (inIdx >= 0) {
                                audioCodec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                                audioInputDone = true;
                            }
                        }
                    } else if (trackIdx == videoTrack && !videoInputDone) {
                        int inIdx = videoCodec.dequeueInputBuffer(TIMEOUT_US);
                        if (inIdx >= 0) {
                            ByteBuffer inBuf = videoCodec.getInputBuffer(inIdx);
                            int sz  = extractor.readSampleData(inBuf, 0);
                            long pts = extractor.getSampleTime();
                            positionUs = pts;
                            if (sz < 0) {
                                videoCodec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                                videoInputDone = true;
                            } else {
                                videoCodec.queueInputBuffer(inIdx, 0, sz, pts, 0);
                                extractor.advance();
                            }
                        }
                    } else if (trackIdx == audioTrack && audioCodec != null && !audioInputDone) {
                        int inIdx = audioCodec.dequeueInputBuffer(TIMEOUT_US);
                        if (inIdx >= 0) {
                            ByteBuffer inBuf = audioCodec.getInputBuffer(inIdx);
                            int sz  = extractor.readSampleData(inBuf, 0);
                            long pts = extractor.getSampleTime();
                            if (sz < 0) {
                                audioCodec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                                audioInputDone = true;
                            } else {
                                audioCodec.queueInputBuffer(inIdx, 0, sz, pts, 0);
                                extractor.advance();
                            }
                        }
                    } else {
                        extractor.advance(); // skip unknown track
                    }
                }

                // ── Drain video output → Surface (timestamp-based rendering) ──
                videoOutputDone |= drainVideoOutput(videoCodec, info, 0, false);

                // ── Drain audio output → Mp4AudioExtractor queue ─────────────
                if (audioCodec != null && !audioOutputDone) {
                    int outIdx = audioCodec.dequeueOutputBuffer(info, 0);
                    if (outIdx >= 0) {
                        if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            audioOutputDone = true;
                        }
                        if (info.size > 0) {
                            ByteBuffer outBuf = audioCodec.getOutputBuffer(outIdx);
                            byte[] pcm = new byte[info.size];
                            outBuf.get(pcm);
                            audioCodec.releaseOutputBuffer(outIdx, false);
                            Mp4AudioExtractor.instance.pushPcm(pcm);
                        } else {
                            audioCodec.releaseOutputBuffer(outIdx, false);
                        }
                    }
                }

                // Frame pacing: sleep a tiny bit to avoid busy-spinning
                try { Thread.sleep(1); } catch (InterruptedException ignored) {}
            }

            videoCodec.stop();
            videoCodec.release();
            if (audioCodec != null) { audioCodec.stop(); audioCodec.release(); }
            Log.i(TAG, "Demux finished (EOS)");

        } finally {
            extractor.release();
        }
    }

    /** Drain one video output buffer. Returns true if EOS reached. */
    private boolean drainVideoOutput(MediaCodec codec, MediaCodec.BufferInfo info, long timeoutUs, boolean flush) {
        boolean eos = false;
        int outIdx;
        do {
            outIdx = codec.dequeueOutputBuffer(info, timeoutUs);
            if (outIdx >= 0) {
                if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) eos = true;
                // Release to surface — SurfaceTexture callback fires → WebRTC frame captured
                codec.releaseOutputBuffer(outIdx, true);
            }
        } while (flush && outIdx >= 0 && !eos);
        return eos;
    }

    private void openExtractor(MediaExtractor extractor, String raw) throws IOException {
        if (raw.startsWith("content://") || raw.startsWith("file://")) {
            Uri uri = Uri.parse(raw);
            ContentResolver cr = appContext.getContentResolver();
            try (AssetFileDescriptor afd = cr.openAssetFileDescriptor(uri, "r")) {
                if (afd == null) throw new IOException("ContentResolver returned null for: " + raw);
                extractor.setDataSource(afd.getFileDescriptor(), afd.getStartOffset(), afd.getLength());
                return;
            }
        }
        File file = new File(raw);
        if (file.exists()) {
            try (ParcelFileDescriptor pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)) {
                extractor.setDataSource(pfd.getFileDescriptor());
                return;
            }
        }
        extractor.setDataSource(raw);
    }
}
