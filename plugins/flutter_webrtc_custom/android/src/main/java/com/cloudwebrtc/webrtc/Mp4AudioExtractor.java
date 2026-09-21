package com.cloudwebrtc.webrtc;

import android.content.Context;
import android.util.Log;

import java.nio.ByteBuffer;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Audio PCM queue — fed directly by Mp4Capturer's unified demux loop.
 * No separate decoder, no separate MediaExtractor.
 * Audio and video come from the SAME extractor → perfect sync, zero drift.
 *
 * WebRTC's AudioBufferCallback calls readSamples() which:
 *  1. Pulls raw native-rate PCM from the queue
 *  2. Applies linear-interpolation resampling to exactly match WebRTC's requested rate/channels
 */
public class Mp4AudioExtractor {
    private static final String TAG = "Mp4AudioExtractor";

    public static final Mp4AudioExtractor instance = new Mp4AudioExtractor();

    private final AtomicBoolean active = new AtomicBoolean(false);

    private static final int MAX_QUEUE_BYTES = 512 * 1024; // ~3s at 44100 stereo
    private final LinkedBlockingDeque<byte[]> pcmQueue = new LinkedBlockingDeque<>();
    private volatile int queuedBytes = 0;

    // Carry-over buffer for partial samples between readSamples calls
    private byte[] carryBuf = new byte[0];
    private int    carryLen = 0;

    // Native format of the MP4 audio track (set by Mp4Capturer when track is opened)
    private volatile int srcSampleRate   = 44100;
    private volatile int srcChannelCount = 2;

    private Context appContext;
    private Mp4AudioExtractor() {}

    // ── Called by Mp4Capturer ──────────────────────────────────────────

    /** Called when Mp4Capturer starts — just resets state */
    public synchronized void start(Context ctx, String rawPath) {
        appContext = ctx.getApplicationContext();
        active.set(true);
        pcmQueue.clear();
        queuedBytes = 0;
        carryLen    = 0;
        Log.i(TAG, "ready (PCM will be pushed by Mp4Capturer demux)");
    }

    /** Called by Mp4Capturer when it knows the native audio format */
    public void setNativeFormat(int sampleRate, int channelCount) {
        this.srcSampleRate   = sampleRate;
        this.srcChannelCount = channelCount;
        Log.i(TAG, "native format: " + sampleRate + " Hz, " + channelCount + " ch");
    }

    /** Push raw decoded PCM bytes (native format) — called by Mp4Capturer demux thread */
    public void pushPcm(byte[] pcm) {
        if (!active.get()) return;
        // Back-pressure: drop oldest chunk if queue overflows
        while (queuedBytes > MAX_QUEUE_BYTES) {
            byte[] dropped = pcmQueue.poll();
            if (dropped == null) break;
            synchronized (this) { queuedBytes -= dropped.length; }
        }
        pcmQueue.add(pcm);
        synchronized (this) { queuedBytes += pcm.length; }
    }

    public void clearQueue() {
        pcmQueue.clear();
        synchronized (this) { queuedBytes = 0; }
        carryLen = 0;
    }

    public boolean isActive() { return active.get(); }

    public synchronized void stop() {
        active.set(false);
        pcmQueue.clear();
        queuedBytes = 0;
        carryLen    = 0;
        Log.i(TAG, "stopped");
    }

    // These are called by MainActivity to stay compatible with existing Kotlin code
    public void pause()        { /* pausing is handled in Mp4Capturer */ }
    public void resume()       { /* resuming is handled in Mp4Capturer */ }
    public void seekTo(long ms){ clearQueue(); }

    // ── Called by WebRTC AudioBufferCallback ──────────────────────────

    /**
     * Fills dst with exactly dst.remaining() bytes of 16-bit PCM
     * at (reqSampleRate, reqChannels) using linear interpolation resampling.
     */
    public int readSamples(ByteBuffer dst, int reqSampleRate, int reqChannels) {
        final int needed       = dst.remaining();
        final int dstFrames    = needed / (2 * reqChannels);
        final int srcRate      = srcSampleRate;
        final int srcCh        = srcChannelCount;

        // How many native src frames do we need to produce dstFrames?
        final int srcFramesNeeded = (int)((long)dstFrames * srcRate / reqSampleRate) + 2;
        final int rawBytesNeeded  = srcFramesNeeded * 2 * srcCh;

        byte[] raw = pullRawBytes(rawBytesNeeded);
        byte[] out = resampleLerp(raw, srcFramesNeeded, srcRate, srcCh,
                                   dstFrames, reqSampleRate, reqChannels);

        dst.rewind();
        int toCopy = Math.min(out.length, needed);
        dst.put(out, 0, toCopy);
        for (int i = toCopy; i < needed; i++) dst.put((byte) 0); // silence pad
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

    private static byte[] resampleLerp(byte[] raw, int srcFrames,
                                        int srcRate, int srcCh,
                                        int dstFrames, int dstRate, int dstCh) {
        byte[] out   = new byte[dstFrames * 2 * dstCh];
        double ratio = (double) srcRate / dstRate;

        for (int i = 0; i < dstFrames; i++) {
            double srcPos = i * ratio;
            int    idx0   = (int) srcPos;
            int    idx1   = Math.min(idx0 + 1, srcFrames - 1);
            float  frac   = (float)(srcPos - idx0);

            for (int c = 0; c < dstCh; c++) {
                short s0, s1;
                if (dstCh == 1 && srcCh > 1) {
                    // Mix stereo → mono
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
                short sample  = (short)(s0 + frac * (s1 - s0));
                int   dstByte = (i * dstCh + c) * 2;
                out[dstByte]     = (byte)(sample & 0xFF);
                out[dstByte + 1] = (byte)((sample >> 8) & 0xFF);
            }
        }
        return out;
    }

    private static short readShort(byte[] buf, int frame, int ch, int numCh) {
        int idx = (frame * numCh + ch) * 2;
        if (idx + 1 >= buf.length) return 0;
        return (short)((buf[idx] & 0xFF) | (buf[idx + 1] << 8));
    }

    public int getSampleRate()   { return srcSampleRate; }
    public int getChannelCount() { return srcChannelCount; }
}
