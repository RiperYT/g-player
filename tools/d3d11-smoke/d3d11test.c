// D3D11 smoke test: device, dynamic buffer map, GPU copy + readback, render-target clear + readback, and a swap
// chain presenting a few frames. Prints one line per step and exits 0 when all pass ("--no-window" skips the
// swap chain). Checks DXVK and MoltenVK in an engine without a game, e.g. after a MoltenVK update:
//   i686-w64-mingw32-gcc -O1 -o d3d11test32.exe d3d11test.c -ld3d11 -ldxgi -luuid -ldxguid   (and x86_64-…)
// Put the exe and DXVK's d3d11.dll and d3d10core.dll (x32 or x64) in a folder inside a test prefix's drive_c, then
//   WINEPREFIX=… WINEDLLOVERRIDES="d3d11,d3d10core=n,b" DXVK_LOG_LEVEL=info arch -x86_64 wine 'C:\t\d3d11test32.exe'
// VK_DRIVER_FILES=<folder>/MoltenVK_icd.json tries another MoltenVK without touching the engine.
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <d3dcommon.h>

static int fail(const char *step, HRESULT hr) { printf("FAIL %s hr=0x%08lx\n", step, (unsigned long)hr); fflush(stdout); return 1; }
static void ok(const char *step) { printf("OK   %s\n", step); fflush(stdout); }

int main(int argc, char **argv) {
    ID3D11Device *dev = NULL; ID3D11DeviceContext *ctx = NULL; D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &dev, &fl, &ctx);
    if (FAILED(hr)) return fail("D3D11CreateDevice", hr);
    printf("OK   D3D11CreateDevice feature level 0x%x, pointer size %u\n", fl, (unsigned)sizeof(void*)); fflush(stdout);

    // Dynamic buffer: CPU writes through Map.
    D3D11_BUFFER_DESC bd = { 4096, D3D11_USAGE_DYNAMIC, D3D11_BIND_VERTEX_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0 };
    ID3D11Buffer *dyn = NULL;
    if (FAILED(hr = ID3D11Device_CreateBuffer(dev, &bd, NULL, &dyn))) return fail("CreateBuffer dynamic", hr);
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource*)dyn, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return fail("Map dynamic", hr);
    printf("OK   Map dynamic at %p\n", m.pData); fflush(stdout);
    for (int i = 0; i < 1024; i++) ((unsigned*)m.pData)[i] = 0xC0DE0000u + i;
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource*)dyn, 0);

    // Default buffer with initial data, copied by the GPU into a staging buffer and read back.
    unsigned init[1024]; for (int i = 0; i < 1024; i++) init[i] = 0xBEEF0000u + i;
    D3D11_SUBRESOURCE_DATA sd = { init, 0, 0 };
    D3D11_BUFFER_DESC db = { 4096, D3D11_USAGE_DEFAULT, D3D11_BIND_SHADER_RESOURCE, 0, 0, 0 };
    ID3D11Buffer *def = NULL;
    if (FAILED(hr = ID3D11Device_CreateBuffer(dev, &db, &sd, &def))) return fail("CreateBuffer default", hr);
    D3D11_BUFFER_DESC sb = { 4096, D3D11_USAGE_STAGING, 0, D3D11_CPU_ACCESS_READ, 0, 0 };
    ID3D11Buffer *stg = NULL;
    if (FAILED(hr = ID3D11Device_CreateBuffer(dev, &sb, NULL, &stg))) return fail("CreateBuffer staging", hr);
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource*)stg, (ID3D11Resource*)def);
    if (FAILED(hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource*)stg, 0, D3D11_MAP_READ, 0, &m))) return fail("Map staging", hr);
    int good = memcmp(m.pData, init, sizeof init) == 0;
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource*)stg, 0);
    if (!good) return fail("buffer readback mismatch", E_FAIL);
    ok("buffer GPU copy + readback");

    // Render target cleared by the GPU, copied to a staging texture and read back.
    D3D11_TEXTURE2D_DESC td = { 64, 64, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET, 0, 0 };
    ID3D11Texture2D *rt = NULL;
    if (FAILED(hr = ID3D11Device_CreateTexture2D(dev, &td, NULL, &rt))) return fail("CreateTexture2D render target", hr);
    ID3D11RenderTargetView *rtv = NULL;
    if (FAILED(hr = ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource*)rt, NULL, &rtv))) return fail("CreateRenderTargetView", hr);
    float color[4] = { 1.0f, 0.5f, 0.0f, 1.0f };
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, color);
    td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Texture2D *st = NULL;
    if (FAILED(hr = ID3D11Device_CreateTexture2D(dev, &td, NULL, &st))) return fail("CreateTexture2D staging", hr);
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource*)st, (ID3D11Resource*)rt);
    if (FAILED(hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource*)st, 0, D3D11_MAP_READ, 0, &m))) return fail("Map staging texture", hr);
    unsigned px = *(unsigned*)m.pData;
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource*)st, 0);
    printf("%s texture readback pixel 0x%08x (want 0xff0080ff or 0xff007fff)\n",
           (px == 0xff0080ffu || px == 0xff007fffu) ? "OK  " : "FAIL", px); fflush(stdout);
    if (px != 0xff0080ffu && px != 0xff007fffu) return 1;

    // A triangle drawn by shaders (compiled at run time) over the whole target, in a colour the pixel shader reads from
    // a dynamic constant buffer: shader translation down to Metal, and the GPU reading memory the CPU wrote.
    HRESULT (WINAPI *compile)(const void*, SIZE_T, const char*, const void*, void*, const char*, const char*, UINT, UINT,
                              ID3DBlob**, ID3DBlob**) = NULL;
    HMODULE compiler = LoadLibraryA("d3dcompiler_47.dll");
    if (compiler) compile = (void*)GetProcAddress(compiler, "D3DCompile");
    if (!compile) return fail("load D3DCompile", E_FAIL);
    static const char vsSource[] =
        "float4 main(uint id : SV_VertexID) : SV_Position {"
        "  float2 p = float2((id << 1) & 2, id & 2); return float4(p * float2(2, -2) + float2(-1, 1), 0, 1); }";
    static const char psSource[] =
        "cbuffer c : register(b0) { float4 colour; }; float4 main() : SV_Target { return colour; }";
    ID3DBlob *vsBlob = NULL, *psBlob = NULL, *errors = NULL;
    if (FAILED(hr = compile(vsSource, sizeof vsSource - 1, "vs", NULL, NULL, "main", "vs_4_0", 0, 0, &vsBlob, &errors))) return fail("compile vertex shader", hr);
    if (FAILED(hr = compile(psSource, sizeof psSource - 1, "ps", NULL, NULL, "main", "ps_4_0", 0, 0, &psBlob, &errors))) return fail("compile pixel shader", hr);
    ID3D11VertexShader *vs = NULL; ID3D11PixelShader *ps = NULL;
    if (FAILED(hr = ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(vsBlob), ID3D10Blob_GetBufferSize(vsBlob), NULL, &vs))) return fail("CreateVertexShader", hr);
    if (FAILED(hr = ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(psBlob), ID3D10Blob_GetBufferSize(psBlob), NULL, &ps))) return fail("CreatePixelShader", hr);
    D3D11_BUFFER_DESC cbd = { 16, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0 };
    ID3D11Buffer *cb = NULL;
    if (FAILED(hr = ID3D11Device_CreateBuffer(dev, &cbd, NULL, &cb))) return fail("CreateBuffer constant", hr);
    if (FAILED(hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource*)cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return fail("Map constant", hr);
    float colour[4] = { 0.25f, 0.5f, 0.75f, 1.0f };
    memcpy(m.pData, colour, sizeof colour);
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource*)cb, 0);
    float black[4] = { 0, 0, 0, 1 };
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, black);
    D3D11_VIEWPORT vp = { 0, 0, 64, 64, 0, 1 };
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
    ID3D11DeviceContext_PSSetConstantBuffers(ctx, 0, 1, &cb);
    ID3D11DeviceContext_Draw(ctx, 3, 0);
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource*)st, (ID3D11Resource*)rt);
    if (FAILED(hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource*)st, 0, D3D11_MAP_READ, 0, &m))) return fail("Map staging texture after draw", hr);
    unsigned drawn = ((unsigned*)m.pData)[32 * (m.RowPitch / 4) + 32];          // the middle pixel
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource*)st, 0);
    int r = drawn & 0xff, g = (drawn >> 8) & 0xff, b = (drawn >> 16) & 0xff;
    int drewIt = abs(r - 0x40) <= 1 && abs(g - 0x80) <= 1 && abs(b - 0xbf) <= 1;
    printf("%s shader draw pixel 0x%08x (want about 0xffbf8040)\n", drewIt ? "OK  " : "FAIL", drawn); fflush(stdout);
    if (!drewIt) return 1;

    if (argc > 1 && !strcmp(argv[1], "--no-window")) { printf("DONE\n"); return 0; }

    // A small window with a swap chain, presenting 120 frames.
    WNDCLASSA wc = { 0, DefWindowProcA, 0, 0, GetModuleHandleA(NULL), NULL, NULL, NULL, NULL, "d3d11test" };
    RegisterClassA(&wc);
    HWND wnd = CreateWindowA("d3d11test", "d3d11test", WS_OVERLAPPEDWINDOW, 0, 0, 160, 120, NULL, NULL, wc.hInstance, NULL);
    ShowWindow(wnd, SW_SHOWNOACTIVATE);
    IDXGIDevice *dxgiDev = NULL; IDXGIAdapter *adapter = NULL; IDXGIFactory *factory = NULL;
    ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void**)&dxgiDev);
    IDXGIDevice_GetAdapter(dxgiDev, &adapter);
    IDXGIAdapter_GetParent(adapter, &IID_IDXGIFactory, (void**)&factory);
    DXGI_SWAP_CHAIN_DESC scd; memset(&scd, 0, sizeof scd);
    scd.BufferDesc.Width = 160; scd.BufferDesc.Height = 120; scd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    scd.SampleDesc.Count = 1; scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; scd.BufferCount = 2;
    scd.OutputWindow = wnd; scd.Windowed = TRUE; scd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    IDXGISwapChain *sc = NULL;
    if (FAILED(hr = IDXGIFactory_CreateSwapChain(factory, (IUnknown*)dev, &scd, &sc))) return fail("CreateSwapChain", hr);
    ok("CreateSwapChain");
    for (int f = 0; f < 120; f++) {
        MSG msg; while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        ID3D11Texture2D *back = NULL; ID3D11RenderTargetView *bv = NULL;
        IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void**)&back);
        ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource*)back, NULL, &bv);
        float c[4] = { f / 120.0f, 0.2f, 0.6f, 1.0f };
        ID3D11DeviceContext_ClearRenderTargetView(ctx, bv, c);
        if (FAILED(hr = IDXGISwapChain_Present(sc, 1, 0))) return fail("Present", hr);
        ID3D11RenderTargetView_Release(bv); ID3D11Texture2D_Release(back);
    }
    ok("Present 120 frames");
    printf("DONE\n");
    return 0;
}
