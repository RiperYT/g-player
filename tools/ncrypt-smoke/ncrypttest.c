// NCrypt smoke test: an ECDSA P-256 key in the software key storage provider, as Epic's launcher makes one for its DPoP
// proofs; its public part exported, a hash signed with it and the signature checked with BCrypt. Prints one line per step
// and exits 0 when all pass. Checks an engine's ncrypt.dll without a launcher:
//   x86_64-w64-mingw32-gcc -O1 -o ncrypttest.exe ncrypttest.c -lncrypt -lbcrypt   (and i686-…)
//   WINEPREFIX=… arch -x86_64 wine 'C:\t\ncrypttest.exe'
#include <windows.h>
#include <bcrypt.h>
#include <ncrypt.h>
#include <stdio.h>

static int fail(const char *step, long status) { printf("FAIL %s status=0x%08lx\n", step, (unsigned long)status); fflush(stdout); return 1; }
static void ok(const char *step) { printf("OK   %s\n", step); fflush(stdout); }

int main(void) {
    NCRYPT_PROV_HANDLE prov = 0;
    NCRYPT_KEY_HANDLE key = 0;
    SECURITY_STATUS s = NCryptOpenStorageProvider(&prov, MS_KEY_STORAGE_PROVIDER, 0);
    if (s != ERROR_SUCCESS) return fail("NCryptOpenStorageProvider", s);
    ok("NCryptOpenStorageProvider");
    s = NCryptCreatePersistedKey(prov, &key, BCRYPT_ECDSA_P256_ALGORITHM, L"gplayer-ncrypt-test", 0, NCRYPT_OVERWRITE_KEY_FLAG);
    if (s != ERROR_SUCCESS) return fail("NCryptCreatePersistedKey ECDSA_P256", s);
    ok("NCryptCreatePersistedKey ECDSA_P256");
    if ((s = NCryptFinalizeKey(key, 0)) != ERROR_SUCCESS) return fail("NCryptFinalizeKey", s);
    ok("NCryptFinalizeKey");

    BYTE pub[256]; DWORD publen = 0;
    if ((s = NCryptExportKey(key, 0, BCRYPT_ECCPUBLIC_BLOB, NULL, pub, sizeof(pub), &publen, 0)) != ERROR_SUCCESS)
        return fail("NCryptExportKey ECCPUBLIC", s);
    printf("OK   NCryptExportKey ECCPUBLIC %lu bytes\n", publen); fflush(stdout);

    BYTE hash[32]; for (int i = 0; i < 32; i++) hash[i] = (BYTE)(i * 7 + 1);
    BYTE sig[128]; DWORD siglen = 0;
    if ((s = NCryptSignHash(key, NULL, hash, sizeof(hash), sig, sizeof(sig), &siglen, 0)) != ERROR_SUCCESS)
        return fail("NCryptSignHash", s);
    printf("OK   NCryptSignHash %lu bytes\n", siglen); fflush(stdout);

    BCRYPT_KEY_HANDLE bkey = NULL;
    NTSTATUS n = BCryptImportKeyPair(BCRYPT_ECDSA_P256_ALG_HANDLE, NULL, BCRYPT_ECCPUBLIC_BLOB, &bkey, pub, publen, 0);
    if (n) return fail("BCryptImportKeyPair", n);
    if ((n = BCryptVerifySignature(bkey, NULL, hash, sizeof(hash), sig, siglen, 0))) return fail("BCryptVerifySignature", n);
    ok("signature verifies");
    NCryptDeleteKey(key, 0);
    NCryptFreeObject(prov);
    return 0;
}
