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
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.atomic.AtomicBoolean;

public class Mp4AudioExtractor {
    private static final String TAG = "Mp4AudioExtractor";

    public static final Mp4AudioExtractor instance = new Mp4AudioExtractor();

    private final AtomicBoolean active   = new AtomicBoolean(false);
    private final AtomicBoolean paused   = new AtomicBoolean(true);
    private final Object        pauseLock = new Object();

    private static final int MAX_QUEUE_BYTES = 512 * 1024;
    private final LinkedBlockingDeque<byte[]> pcmQueue = new LinkedBlockingDeque<>();
    private volatile int queuedBytes = 0;

    private byte[] carryBuf  = new byte[0];
    private int    carryLen  = 0;

    private volatile int srcSampleRate  = 44100;
    private volatile int srcChannelCount = 2;

    private Thread  decodeThread;
    private String  currentRaw;
    private volatile long pendingSeekMs = -1;
    private Context appContext;

    private Mp4AudioExtractor() {}

    public void start(Context ctx, String rawPath) {
        appContext = ctx.getApplicationContext();
        stop();
        currentRaw  = rawPath;
        pendingSeekMs = -1;
        pcmQueue.clear();
        queuedBytes = 0;
        carryLen    = 0;
        active.set(true);
        paused.set(false);

        decodeThread = new Thread(this::decodeLoop, "Mp4AudioDecode");
        decodeThread.setDaemon(true);
        decodeThread.start();
        Log.i(TAG, "started for: " + rawPath);
    }

    public void pause() { paused.set(true); }

    public void resume() {
        paused.set(false);
        synchronized (pauseLock) { pauseLock.notifyAll(); }
    }

    public void seekTo(long ms) {
        pendingSeekMs = ms;
        pcmQueue.clear();
        synchronized (this) { queuedBytes = 0; }
        carryLen = 0;
        synchronized (pauseLock) { pauseLock.notifyAll(); }
    }

    public synchronized void stop() {
        active.set(false);
        paused.set(false);
        synchronized (pauseLock) { pauseLock.notifyAll(); }
        if (decodeThread != null) {
            decodeThread.interrupt();
            try { decodeThread.join(500); } catch (InterruptedException ignored) {}
            decodeThread = null;
        }
        pcmQueue.clear();
        queuedBytes = 0;
        carryLen    = 0;
    }

    public boolean isActive() { return active.get(); }

    public int readSamples(ByteBuffer dst, int reqSampleRate, int reqChannels) {
        final int needed       = dst.remaining();
        final int dstFrames    = needed / (2 * reqChannels);
        final int srcRate      = srcSampleRate;
        final int srcCh        = srcChannelCount;

        final int srcFramesNeeded = (int)((long)dstFrames * srcRate / reqSampleRate) + 2;
        final int rawBytesNeeded  = srcFramesNeeded * 2 * srcCh;

        byte[] raw = pullRawBytes(rawBytesNeeded);
        byte[] out = resampleLerp(raw, srcFramesNeeded, srcRate, srcCh, dstFrames, reqSampleRate, reqChannels);

        dst.rewind();
        int toCopy = Math.min(out.length, needed);
        dst.put(out, 0, toCopy);
        for (int i = toCopy; i < needed; i++) dst.put((byte) 0);
        return needed;
    }

    private byte[] pullRawBytes(int needed) {
        byte[] buf    = new byte[needed];
        int    filled = 0;

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

        while (filled < needed) {
            byte[] chunk = pcmQueue.poll();
            if (chunk == null) break;
            synchronized (this) { queuedBytes -= chunk.length; }
            int take = Math.min(chunk.length, needed - filled);
            System.arraycopy(chunk, 0, buf, filled, take);
            filled += take;
            if (take < chunk.length) {
                int leftover = chunk.length - take;
                if (carryBuf.length < leftover) carryBuf = new byte[leftover];
                System.arraycopy(chunk, take, carryBuf, 0, leftover);
                carryLen = leftover;
            }
        }
        return buf;
    }

    private static byte[] resampleLerp(byte[] raw, int srcFrames, int srcRate, int srcCh, int dstFrames, int dstRate, int dstCh) {
        byte[] out = new byte[dstFrames * 2 * dstCh];
        double ratio = (double) srcRate / dstRate;

        for (int i = 0; i < dstFrames; i++) {
            double srcPos = i * ratio;
            int    idx0   = (int) srcPos;
            int    idx1   = Math.min(idx0 + 1, srcFrames - 1);
            float  frac   = (float)(srcPos - idx0);

            for (int c = 0; c < dstCh; c++) {
                short s0, s1;
                if (dstCh == 1 && srcCh > 1) {
                    float sum0 = 0, sum1 = 0;
                    for (int sc = 0; sc < srcCh; sc++) {
                        sum0 += readShort(raw, idx0, sc, srcCh);
                        sum1 += readShort(raw, idx1, sc, srcCh);
                    }
                    s0 = (short)(sum0 / srcCh);
                    s1 = (short)(sum1 / srcCh);
                } else {
                    int srcC = (c < srcCh) ? c : srcCh - 1;
                    s0 = readShort(raw, idx0, srcC, srcCh);
                    s1 = readShort(raw, idx1, srcC, srcCh);
                }
                short sample = (short)(s0 + frac * (s1 - s0));

                int dstByte = (i * dstCh + c) * 2;
                out[dstByte]     = (byte)(sample & 0xFF);
                out[dstByte + 1] = (byte)((sample >> 8) & 0xFF);
            }
        }
        return out;
    }

    private static short readShort(byte[] buf, int frame, int ch, int numCh) {
        int byteIdx = (frame * numCh + ch) * 2;
        if (byteIdx + 1 >= buf.length) return 0;
        return (short)((buf[byteIdx] & 0xFF) | (buf[byteIdx + 1] << 8));
    }

    private void decodeLoop() {
        while (active.get()) {
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

            int         audioTrack  = -1;
            MediaFormat audioFormat = null;
            for (int i = 0; i < extractor.getTrackCount(); i++) {
                MediaFormat fmt  = extractor.getTrackFormat(i);
                String      mime = fmt.getString(MediaFormat.KEY_MIME);
                if (mime != null && mime.startsWith("audio/")) {
                    audioTrack  = i;
                    audioFormat = fmt;
                    break;
                }
            }
            if (audioTrack < 0) {
                active.set(false);
                return;
            }
            extractor.selectTrack(audioTrack);

            srcSampleRate   = audioFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE) ? audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE) : 44100;
            srcChannelCount = audioFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT) ? audioFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT) : 2;

            long sk = pendingSeekMs;
            if (sk >= 0) {
                extractor.seekTo(sk * 1000L, MediaExtractor.SEEK_TO_CLOSEST_SYNC);
                pendingSeekMs = -1;
                pcmQueue.clear();
                synchronized (this) { queuedBytes = 0; }
                carryLen = 0;
            }

            String     mime  = audioFormat.getString(MediaFormat.KEY_MIME);
            MediaCodec codec = MediaCodec.createDecoderByType(mime);
            codec.configure(audioFormat, null, null, 0);
            codec.start();

            MediaCodec.BufferInfo info      = new MediaCodec.BufferInfo();
            boolean               inputDone = false;
            boolean               outputDone = false;
            final long            TIMEOUT   = 5_000L;

            while (!outputDone && active.get()) {

                if (paused.get() && pendingSeekMs < 0) {
                    synchronized (pauseLock) {
                        while (active.get() && paused.get() && pendingSeekMs < 0) {
                            try { pauseLock.wait(200); } catch (InterruptedException ignored) {}
                        }
                    }
                }
                if (!active.get()) break;

                long seekMs = pendingSeekMs;
                if (seekMs >= 0) {
                    codec.flush();
                    extractor.seekTo(seekMs * 1000L, MediaExtractor.SEEK_TO_CLOSEST_SYNC);
                    pendingSeekMs = -1;
                    inputDone     = false;
                    pcmQueue.clear();
                    synchronized (this) { queuedBytes = 0; }
                    carryLen = 0;
                    continue;
                }

                if (!inputDone) {
                    int inIdx = codec.dequeueInputBuffer(TIMEOUT);
                    if (inIdx >= 0) {
                        ByteBuffer inBuf = codec.getInputBuffer(inIdx);
                        int sz = extractor.readSampleData(inBuf, 0);
                        if (sz < 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputDone = true;
                        } else {
                            long pts = extractor.getSampleTime();
                            codec.queueInputBuffer(inIdx, 0, sz, pts, 0);
                            extractor.advance();
                        }
                    }
                }

                int outIdx = codec.dequeueOutputBuffer(info, TIMEOUT);
                if (outIdx >= 0) {
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        outputDone = true;
                    }
                    if (info.size > 0) {
                        ByteBuffer outBuf = codec.getOutputBuffer(outIdx);
                        byte[]     pcm    = new byte[info.size];
                        outBuf.get(pcm);
                        codec.releaseOutputBuffer(outIdx, false);

                        while (active.get() && queuedBytes > MAX_QUEUE_BYTES) {
                            try { Thread.sleep(5); } catch (InterruptedException ignored) {}
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
            try (ParcelFileDescriptor pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)) {
                extractor.setDataSource(pfd.getFileDescriptor());
                return;
            }
        }
        extractor.setDataSource(raw);
    }
}
