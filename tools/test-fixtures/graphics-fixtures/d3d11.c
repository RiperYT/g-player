// Imports d3d11.dll (and nothing else graphical). The call keeps the import; it never runs in tests.
#include <windows.h>
#include <d3d11.h>

int WINAPI WinMain(HINSTANCE a, HINSTANCE b, LPSTR c, int d) {
    ID3D11Device *device = NULL;
    D3D_FEATURE_LEVEL level;
    D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &device, &level, NULL);
    return device != NULL;
}
