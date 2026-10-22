// Imports d3d9.dll (and nothing else graphical). The call keeps the import; it never runs in tests.
#include <windows.h>
#include <d3d9.h>

int WINAPI WinMain(HINSTANCE a, HINSTANCE b, LPSTR c, int d) {
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    return d3d != NULL;
}
