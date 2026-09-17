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

import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Decodes the audio track from the same MP4 file as Mp4Capturer and exposes
 * raw PCM samples that WebRTC's AudioBufferCallback can consume.
 *
 * Lifecycle:
 *   start(rawPath)  — opens the file, starts a background decode thread
 *   pause()         — pauses the decode thread
 *   resume()        — resumes decoding
 *   seekTo(ms)      — seeks decoder to the given position
 *   stop()          — shuts down the decoder
 *
 * Thread safety:
 *   All public methods are thread-safe.
 *   Decoded PCM is available via readSamples(dst), called from the WebRTC audio thread.
 */
public class Mp4AudioExtractor {
    private static final String TAG = "Mp4AudioExtractor";

    /** Singleton — shared between Mp4Capturer and MethodCallHandlerImpl */
    public static final Mp4AudioExtractor instance = new Mp4AudioExtractor();

    // ── State ──────────────────────────────────────────────────────────────
    private final AtomicBoolean active  = new AtomicBoolean(false);
    private final AtomicBoolean paused  = new AtomicBoolean(true);
    private final Object        pauseLock = new Object();

    // ── Output buffer ──────────────────────────────────────────────────────
    // Stores decoded interleaved 16-bit PCM shorts as raw bytes (little-endian).
    // We keep up to ~2 s worth of audio at 44100 Hz stereo = ~352 800 bytes.
    private final LinkedBlockingDeque<byte[]> pcmQueue = new LinkedBlockingDeque<>();
    private static final int MAX_QUEUE_BYTES = 352_800;
    private volatile int queuedBytes = 0;

    // Partial carry-over from the last decoded chunk
    private final byte[] carry = new byte[0];
    private byte[] carryBuf = new byte[0];
    private int    carryLen  = 0;

    // ── Format info (set after open) ──────────────────────────────────────
    private volatile int sampleRate  = 44100;
    private volatile int channelCount = 2;

    public int getSampleRate()   { return sampleRate;   }
    public int getChannelCount() { return channelCount; }

    // ── Working state ─────────────────────────────────────────────────────
    private Thread decodeThread;
    private volatile String  currentRaw;
    private volatile Context appContext;
    private volatile long    pendingSeekMs = -1;

    private Mp4AudioExtractor() {}

    // ─────────────────────────────────────────────────────────────────────
    // Public API
    // ─────────────────────────────────────────────────────────────────────

    public synchronized void start(Context ctx, String rawPath) {
        stop(); // stop any previous session
        appContext  = ctx.getApplicationContext();
        currentRaw  = rawPath;
        active.set(true);
        paused.set(true); // wait for an explicit resume()
        pcmQueue.clear();
        queuedBytes = 0;
        carryLen    = 0;

        decodeThread = new Thread(this::decodeLoop, "Mp4AudioExtractor");
        decodeThread.setDaemon(true);
        decodeThread.start();
        Log.i(TAG, "start(): " + rawPath);
    }

    public void resume() {
        paused.set(false);
        synchronized (pauseLock) { pauseLock.notifyAll(); }
        Log.d(TAG, "resume()");
    }

    public void pause() {
        paused.set(true);
        Log.d(TAG, "pause()");
    }

    public void seekTo(long positionMs) {
        pendingSeekMs = positionMs;
        // If paused, the decode thread will handle it on the next resume.
        // If running, the thread will see pendingSeekMs != -1 on next iteration.
        synchronized (pauseLock) { pauseLock.notifyAll(); }
        Log.d(TAG, "seekTo(" + positionMs + " ms)");
    }

    public synchronized void stop() {
        if (!active.get()) return;
        active.set(false);
        paused.set(false);
        synchronized (pauseLock) { pauseLock.notifyAll(); }
        if (decodeThread != null) {
            try { decodeThread.join(1000); } catch (InterruptedException ignored) {}
            decodeThread = null;
        }
        pcmQueue.clear();
        queuedBytes = 0;
        carryLen    = 0;
        Log.i(TAG, "stop()");
    }

    public boolean isActive() { return active.get(); }

    /**
     * Called from the WebRTC audio thread (AudioBufferCallback.onBuffer).
     * Fills dst with raw 16-bit PCM samples (little-endian, interleaved).
     * Returns the number of bytes written; writes silence if not enough data.
     */
    public int readSamples(ByteBuffer dst) {
        int needed = dst.remaining();
        byte[] buf = new byte[needed];
        int filled = 0;

        // Drain carry-over first
        if (carryLen > 0) {
            int take = Math.min(carryLen, needed);
            System.arraycopy(carryBuf, 0, buf, 0, take);
            filled += take;
            if (take < carryLen) {
                System.arraycopy(carryBuf, take, carryBuf, 0, carryLen - take);
                carryLen -= take;
            } else {
                carryLen = 0;
            }
        }

        // Pull from queue
        while (filled < needed) {
            byte[] chunk = pcmQueue.poll();
            if (chunk == null) break; // queue empty — will fill remainder with silence
            synchronized (this) { queuedBytes -= chunk.length; }
            int take = Math.min(chunk.length, needed - filled);
            System.arraycopy(chunk, 0, buf, filled, take);
            filled += take;
            if (take < chunk.length) {
                // Store leftover as new carry buffer
                int leftover = chunk.length - take;
                if (carryBuf.length < leftover) carryBuf = new byte[leftover];
                System.arraycopy(chunk, take, carryBuf, 0, leftover);
                carryLen = leftover;
            }
        }

        // Write to ByteBuffer (silence for missing bytes is already 0)
        dst.put(buf, 0, needed);
        return needed;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Decode loop (background thread)
    // ─────────────────────────────────────────────────────────────────────

    private void decodeLoop() {
        while (active.get()) {
            // Wait if paused
            synchronized (pauseLock) {
                while (active.get() && paused.get() && pendingSeekMs < 0) {
                    try { pauseLock.wait(200); } catch (InterruptedException ignored) {}
                }
            }
            if (!active.get()) break;

            try {
                runDecoder();
            } catch (Exception e) {
                Log.e(TAG, "Decoder error: " + e.getMessage(), e);
                try { Thread.sleep(500); } catch (InterruptedException ignored) {}
            }
        }
        Log.d(TAG, "decodeLoop exited");
    }

    private void runDecoder() throws IOException {
        MediaExtractor extractor = new MediaExtractor();
        try {
            openExtractor(extractor, currentRaw);

            // Find the audio track
            int audioTrack = -1;
            MediaFormat audioFormat = null;
            for (int i = 0; i < extractor.getTrackCount(); i++) {
                MediaFormat fmt = extractor.getTrackFormat(i);
                String mime = fmt.getString(MediaFormat.KEY_MIME);
                if (mime != null && mime.startsWith("audio/")) {
                    audioTrack  = i;
                    audioFormat = fmt;
                    break;
                }
            }
            if (audioTrack < 0) {
                Log.w(TAG, "No audio track found in: " + currentRaw);
                active.set(false);
                return;
            }

            extractor.selectTrack(audioTrack);

            // Read format parameters
            sampleRate   = audioFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)
                          ? audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE) : 44100;
            channelCount = audioFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)
                          ? audioFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT) : 2;

            // Handle pending seek before starting
            long seekMs = pendingSeekMs;
            if (seekMs >= 0) {
                extractor.seekTo(seekMs * 1000L, MediaExtractor.SEEK_TO_CLOSEST_SYNC);
                pendingSeekMs = -1;
                pcmQueue.clear();
                synchronized (this) { queuedBytes = 0; }
                carryLen = 0;
            }

            String mime = audioFormat.getString(MediaFormat.KEY_MIME);
            MediaCodec codec = MediaCodec.createDecoderByType(mime);
            codec.configure(audioFormat, null, null, 0);
            codec.start();

            Log.i(TAG, "Audio decoder started: " + mime +
                  " sr=" + sampleRate + " ch=" + channelCount);

            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            boolean inputDone  = false;
            boolean outputDone = false;
            final long TIMEOUT_US = 5_000L;

            while (!outputDone && active.get()) {
                // ── Handle pause ──────────────────────────────────────
                if (paused.get() && pendingSeekMs < 0) {
                    synchronized (pauseLock) {
                        while (active.get() && paused.get() && pendingSeekMs < 0) {
                            try { pauseLock.wait(200); } catch (InterruptedException ignored) {}
                        }
                    }
                }
                if (!active.get()) break;

                // ── Handle seek ───────────────────────────────────────
                long sk = pendingSeekMs;
                if (sk >= 0) {
                    codec.flush();
                    extractor.seekTo(sk * 1000L, MediaExtractor.SEEK_TO_CLOSEST_SYNC);
                    pendingSeekMs = -1;
                    inputDone = false;
                    pcmQueue.clear();
                    synchronized (this) { queuedBytes = 0; }
                    carryLen = 0;
                    continue;
                }

                // ── Feed input ────────────────────────────────────────
                if (!inputDone) {
                    int inIdx = codec.dequeueInputBuffer(TIMEOUT_US);
                    if (inIdx >= 0) {
                        ByteBuffer inBuf = codec.getInputBuffer(inIdx);
                        int sz = extractor.readSampleData(inBuf, 0);
                        if (sz < 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputDone = true;
                        } else {
                            long pts = extractor.getSampleTime();
                            codec.queueInputBuffer(inIdx, 0, sz, pts, 0);
                            extractor.advance();
                        }
                    }
                }

                // ── Drain output ──────────────────────────────────────
                int outIdx = codec.dequeueOutputBuffer(info, TIMEOUT_US);
                if (outIdx >= 0) {
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        outputDone = true;
                    }
                    if (info.size > 0) {
                        ByteBuffer outBuf = codec.getOutputBuffer(outIdx);
                        byte[] pcm = new byte[info.size];
                        outBuf.get(pcm);
                        codec.releaseOutputBuffer(outIdx, false);

                        // Enqueue PCM, back-pressure when queue is full
                        while (active.get() && queuedBytes > MAX_QUEUE_BYTES) {
                            try { Thread.sleep(10); } catch (InterruptedException ignored) {}
                        }
                        if (active.get()) {
                            pcmQueue.add(pcm);
                            synchronized (this) { queuedBytes += pcm.length; }
                        }
                    } else {
                        codec.releaseOutputBuffer(outIdx, false);
                    }
                }
            }

            codec.stop();
            codec.release();
            Log.i(TAG, "Audio decode loop finished (EOS)");

        } finally {
            extractor.release();
        }
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
            try (ParcelFileDescriptor pfd = ParcelFileDescriptor.open(
                    file, ParcelFileDescriptor.MODE_READ_ONLY)) {
                extractor.setDataSource(pfd.getFileDescriptor());
                return;
            }
        }
        extractor.setDataSource(raw);
    }
}
