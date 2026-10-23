// Media Foundation smoke test: decodes a video file the way games play their intros and cutscenes (a source reader
// with video processing), and checks the frames have a picture. Prints one line per step and exits 0 when frames
// came out and were not black. Checks an engine's GStreamer (winegstreamer) without a game:
//   i686-w64-mingw32-gcc -O1 -o mfvideotest32.exe mfvideotest.c -lmfplat -lmfreadwrite -lmfuuid -lole32   (and x86_64-…)
// Put the exe and an H.264 .mp4 in a folder inside a test prefix's drive_c, then
//   WINEPREFIX=… GST_PLUGIN_SYSTEM_PATH=<engine>/wine/lib/gstreamer-1.0 GST_REGISTRY_FORK=no
//   arch -x86_64 wine 'C:\t\mfvideotest32.exe' 'C:\t\clip.mp4'
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <stdio.h>
#include <stdlib.h>

static int fail(const char *step, HRESULT hr) { printf("FAIL %s hr=0x%08lx\n", step, (unsigned long)hr); fflush(stdout); return 1; }
static void ok(const char *step) { printf("OK   %s\n", step); fflush(stdout); }

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: mfvideotest <file.mp4> [max frames]\n"); return 2; }
    int maxFrames = argc > 2 ? atoi(argv[2]) : 120;
    WCHAR path[MAX_PATH];
    MultiByteToWideChar(CP_ACP, 0, argv[1], -1, path, MAX_PATH);

    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) return fail("CoInitializeEx", hr);
    if (FAILED(hr = MFStartup(MF_VERSION, MFSTARTUP_FULL))) return fail("MFStartup", hr);
    ok("MFStartup");

    IMFAttributes *attrs = NULL;
    MFCreateAttributes(&attrs, 1);
    IMFAttributes_SetUINT32(attrs, &MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    IMFSourceReader *reader = NULL;
    if (FAILED(hr = MFCreateSourceReaderFromURL(path, attrs, &reader))) return fail("MFCreateSourceReaderFromURL", hr);
    ok("MFCreateSourceReaderFromURL");

    // What the file has: the native type of the first video stream says which decoder Wine needs.
    IMFMediaType *native = NULL;
    if (FAILED(hr = IMFSourceReader_GetNativeMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &native)))
        return fail("GetNativeMediaType video", hr);
    GUID subtype; IMFMediaType_GetGUID(native, &MF_MT_SUBTYPE, &subtype);
    UINT64 size = 0; IMFMediaType_GetUINT64(native, &MF_MT_FRAME_SIZE, &size);
    UINT32 width = (UINT32)(size >> 32), height = (UINT32)size;
    printf("OK   native video %.4s %ux%u\n", (const char *)&subtype.Data1, width, height); fflush(stdout);

    IMFMediaType *out = NULL;
    MFCreateMediaType(&out);
    IMFMediaType_SetGUID(out, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    IMFMediaType_SetGUID(out, &MF_MT_SUBTYPE, &MFVideoFormat_RGB32);
    if (FAILED(hr = IMFSourceReader_SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, out)))
        return fail("SetCurrentMediaType RGB32", hr);
    ok("SetCurrentMediaType RGB32");

    // Audio, when there is any: games decode it to PCM next to the video.
    IMFMediaType *pcm = NULL;
    MFCreateMediaType(&pcm);
    IMFMediaType_SetGUID(pcm, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    IMFMediaType_SetGUID(pcm, &MF_MT_SUBTYPE, &MFAudioFormat_PCM);
    BOOL audio = SUCCEEDED(IMFSourceReader_SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, NULL, pcm));
    printf("%s audio %s\n", audio ? "OK  " : "--  ", audio ? "to PCM" : "none (or no decoder)"); fflush(stdout);

    // Video first, alone, then the audio from the start.
    IMFSourceReader_SetStreamSelection(reader, MF_SOURCE_READER_ALL_STREAMS, FALSE);
    IMFSourceReader_SetStreamSelection(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
    int frames = 0, lit = 0, audioBuffers = 0;
    for (int pass = 0; pass < (audio ? 2 : 1); pass++) {
        DWORD which = pass ? MF_SOURCE_READER_FIRST_AUDIO_STREAM : MF_SOURCE_READER_FIRST_VIDEO_STREAM;
        if (pass) {
            PROPVARIANT start; PropVariantInit(&start); start.vt = VT_I8; start.hVal.QuadPart = 0;
            IMFSourceReader_SetStreamSelection(reader, MF_SOURCE_READER_ALL_STREAMS, FALSE);
            IMFSourceReader_SetStreamSelection(reader, which, TRUE);
            static const GUID timeFormat = { 0 };  // GUID_NULL: 100-ns units
            IMFSourceReader_SetCurrentPosition(reader, &timeFormat, &start);
        }
        for (int n = 0; n < maxFrames; n++) {
            DWORD stream = 0, flags = 0; LONGLONG time = 0; IMFSample *sample = NULL;
            if (FAILED(hr = IMFSourceReader_ReadSample(reader, which, 0, &stream, &flags, &time, &sample)))
                return fail(pass ? "ReadSample audio" : "ReadSample video", hr);
            if (flags & MF_SOURCE_READERF_ENDOFSTREAM) { if (sample) IMFSample_Release(sample); break; }
            if (!sample) continue;
            IMFMediaBuffer *buf = NULL; BYTE *data = NULL; DWORD len = 0;
            IMFSample_ConvertToContiguousBuffer(sample, &buf);
            IMFMediaBuffer_Lock(buf, &data, NULL, &len);
            if (!pass) {
                unsigned long long sum = 0;
                for (DWORD i = 0; i + 3 < len; i += 4) sum += data[i] + data[i + 1] + data[i + 2];
                unsigned mean = len >= 4 ? (unsigned)(sum / (len / 4 * 3)) : 0;
                if (mean > 8) lit++;
                if (frames == 0) { printf("OK   first frame %lu bytes, mean %u\n", (unsigned long)len, mean); fflush(stdout); }
                frames++;
            } else if (len) {
                audioBuffers++;
            }
            IMFMediaBuffer_Unlock(buf);
            IMFMediaBuffer_Release(buf);
            IMFSample_Release(sample);
        }
    }
    printf("%s frames %d, with a picture %d, audio buffers %d\n", frames && lit ? "OK  " : "FAIL", frames, lit, audioBuffers);
    fflush(stdout);
    IMFSourceReader_Release(reader);
    MFShutdown();
    return frames && lit && (!audio || audioBuffers) ? 0 : 1;
}
