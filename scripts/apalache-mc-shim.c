/* apalache-mc.exe — launcher shim for ModelMirrors on Windows.
 *
 * Why: the Haskell `process` library (CreateProcess) cannot run a .bat/.cmd
 * launcher, and apalache ships as bin/apalache-mc.bat + lib/apalache.jar.
 * This shim wraps the .bat via cmd.exe, inherits stdio, and forwards the
 * child's exit code verbatim so the mirror's VALID/INVALID/infrastructure
 * classification (0/12/120/255) keeps working.
 *
 * Process-tree hygiene: the child (cmd -> java) is assigned to a Job Object
 * with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. When the mirror terminates this
 * shim (e.g. explorer-server teardown), the kernel closes the job handle at
 * process exit and the whole tree dies — no orphan JVMs, no leaked ports.
 * (The job handle is intentionally NOT closed early: associated processes
 * keep the job alive, so children survive while the shim runs, and the
 * KILL_ON_JOB_CLOSE flag only fires when the shim's own exit closes the
 * last external handle.) The child is created suspended and only resumed
 * after job assignment, so the whole cmd -> java tree is captured up front.
 *
 * Compile (git-bash on the target box, GHC-bundled clang):
 *   clang --target=x86_64-unknown-windows-gnu -O2 -o apalache-mc.exe apalache-mc-shim.c
 *
 * The .bat path is baked in; to re-point apalache, rebuild or drop a new
 * shim in and update APALACHE_MC.
 */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#ifndef APALACHE_BAT_W
#define APALACHE_BAT_W L"D:\\Programs\\apalache\\bin\\apalache-mc.bat"
#endif

/* CreateProcessW caps the command line at 32767 chars incl. the null; */
#define MAX_CMDLINE 32768   /* buffer: 32767 chars + null */

static void fail(const wchar_t *what) {
  DWORD err = GetLastError();
  wchar_t buf[512];
  swprintf(buf, 512, L"apalache-mc shim: %ls failed (error %lu)\n", what, (unsigned long)err);
  fputws(buf, stderr);
}

int main(void) {
  LPWSTR raw = GetCommandLineW();
  if (raw == NULL) { fputws(L"apalache-mc shim: GetCommandLineW failed\n", stderr); return 255; }

  /* Find the argument tail: skip argv[0], respecting a quoted program path. */
  LPWSTR p = raw;
  if (*p == L'"') {
    p++;
    while (*p && *p != L'"') {
      if (*p == L'\\' && *(p + 1) == L'"') p++;   /* escaped quote inside program path */
      p++;
    }
    if (*p == L'"') p++;
  } else {
    while (*p && *p != L' ' && *p != L'\t') p++;
  }
  while (*p == L' ' || *p == L'\t') p++;
  LPWSTR tail = p;

  /* Build: cmd.exe /c ""<bat>" <args>"  (canonical cmd quoting). */
  wchar_t cmdline[MAX_CMDLINE];
  int n = swprintf(cmdline, MAX_CMDLINE, L"cmd.exe /c \"\"%ls\"%s%s\"",
                   APALACHE_BAT_W,
                   (*tail != L'\0') ? L" " : L"",
                   (*tail != L'\0') ? tail : L"");
  if (n < 0 || n >= MAX_CMDLINE - 1) { /* >= 32767 chars would exceed CreateProcessW's limit */
    fputws(L"apalache-mc shim: command line too long\n", stderr);
    return 255;
  }

  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput  = GetStdHandle(STD_INPUT_HANDLE);
  si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  si.hStdError  = GetStdHandle(STD_ERROR_HANDLE);
  ZeroMemory(&pi, sizeof(pi));

  /* CREATE_SUSPENDED: the child must be inside the job before cmd starts
   * executing, or cmd could spawn java first and java would escape the job
   * (orphan JVM, leaked port). We resume it after assignment below. */
  BOOL ok = CreateProcessW(
      NULL, cmdline, NULL, NULL, TRUE,
      CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
      NULL, NULL, &si, &pi);
  if (!ok) { fail(L"CreateProcess"); return 255; }

  /* Job object: kill the whole tree when this shim dies. Keep the handle;
   * the kernel closes it at process exit, which is when the kill fires. */
  /* Fail fast: if the kill-tree guarantee cannot be established we must NOT
   * resume the child — a suspended cmd/java running outside the job would
   * orphan JVMs and leak ports while the mirror believes it is protected.
   * Terminate the suspended child and report 255 (infrastructure failure). */
  HANDLE job = CreateJobObjectW(NULL, NULL);
  if (job == NULL) {
    fail(L"CreateJobObject");
    TerminateProcess(pi.hProcess, 255);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return 255;
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli;
  ZeroMemory(&jeli, sizeof(jeli));
  jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli))) {
    fail(L"SetInformationJobObject");
    TerminateProcess(pi.hProcess, 255);
    CloseHandle(job);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return 255;
  }
  if (!AssignProcessToJobObject(job, pi.hProcess)) {
    fail(L"AssignProcessToJobObject");
    TerminateProcess(pi.hProcess, 255);
    CloseHandle(job);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return 255;
  }

  /* Child is still suspended; release it (job membership is guaranteed, or we returned 255 above). */
  if (ResumeThread(pi.hThread) == (DWORD)-1) {
    fail(L"ResumeThread");
    /* The mirror will time out and terminate this shim; nothing more to do. */
  }

  if (WaitForSingleObject(pi.hProcess, INFINITE) != WAIT_OBJECT_0) {
    fail(L"WaitForSingleObject");
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return 255;
  }

  DWORD code = 255;
  if (!GetExitCodeProcess(pi.hProcess, &code)) fail(L"GetExitCodeProcess");
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  return (int)code;
}
