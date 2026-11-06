{ Writing the rebuilt JPEG to disk, without following links and checking the
  hash. The part that touches the filesystem, apart from the format.

  The path is chosen by the user, not by the file: there are no inner names
  to contain. What is left is not to write THROUGH whatever is already at the
  destination -- a symbolic or hard link with the output's name --, not to
  leave half-done writes, and not to leave a file whose hash does not match
  under its name.

  Paths are UTF-8 in RawByteString and are treated as bytes. On Windows they
  are converted to UTF-16 only when calling the API (the W functions).

  The system calls are the ones the reference module's Rust std made (lstat,
  open O_EXCL, mkdir 0777, rename; on Windows CreateFileW CREATE_NEW,
  MoveFileExW), with the same error codes; and link to give a temporary its
  name without replacing anything (MoveFileExW without REPLACE_EXISTING).

  Since 0.9.5 a write is also durable and leaves nothing behind when it is
  interrupted: the data reaches the disk (fsync, FlushFileBuffers) before
  the temporary takes the output's name, and the directory after it (Unix;
  Windows has no such call); SIGINT, SIGTERM, SIGHUP and SIGPIPE (Ctrl-C
  and closing the console on Windows) delete the temporaries still being
  written; and what a SIGKILL or a crash leaves (.pja-tmp-<pid>-<n>) is
  reported by the next run that writes in that directory, and deleted when
  asked (--clean-temps), never while its process lives. }
unit pjafs;
{$I pja.inc}

interface

uses
  SysUtils, pjablake3;


type
  { What to do with an already written file whose hash does not match. The
    default is Delete: a file with a good name and bad contents is worse than
    no file. Keep leaves it under ANOTHER name, never its own. }
  TOnMismatch = (omDelete, omKeep);

  TOutcomeKind = (ocVerified, ocDeleted, ocKept);
  TOutcome = record
    kind: TOutcomeKind;
    path: RawByteString;           { Verified and Kept }
    expected, actual: THash16;     { Deleted and Kept }
  end;

  TFsError = (feNone,
              { Could not write. Whatever was written is already deleted. }
              feIo,
              { The hash did not match, keeping was requested, and it could
                not be renamed. The file was deleted. }
              feCouldNotKeep,
              { Written and given its name (outcome.path), but the directory
                could not be flushed after: the file is there and whole, but
                a power cut may still lose its name. Not a success either. }
              feNotSynced);
  TFsResult = record
    error: TFsError;
    { errno on Unix, GetLastError on Windows; -1 if the error did not come
      from the system ("no free .corrupt names left"). }
    code: LongInt;
    function Ok: Boolean;
    { "Io(13)", "CouldNotKeep(-)" }
    function Text: string;
  end;

{ Writes the file if `data` has the hash `expected`. It is written to a new
  temporary (.pja-tmp-<pid>-<n> in the same directory) and given the name
  only once complete and flushed to the disk (the directory too, after):
  an existing file is never opened, and links are not followed.
  Without `overwrite` the name is only taken if free; with it, the temporary
  is renamed over the target: what was there is only replaced by something
  that verified. If the hash does not match, nothing is written under that
  name (with omKeep, it stays as <file>.corrupt[.N], or pja.corrupt[.N]
  beside it if that name is too long). }
function WriteVerified(const fileName: RawByteString; const data: TBytes; const expected: THash16;
                       onMismatch: TOnMismatch; overwrite: Boolean; out outcome: TOutcome): TFsResult;

var
  { Each file reaches the disk before it takes its name, and the directory
    after (Unix). False (pja --no-sync) leaves
    both to the system: faster on a real disk, but a power cut may leave an
    output empty or missing. Set once, before any write. }
  SyncToDisk: Boolean = True;

{ Exposed for the tests. Path::parent; False at the root or with an empty path. }
function Parent(const p: RawByteString; out q: RawByteString): Boolean;

{ SIGINT, SIGTERM, SIGHUP and SIGPIPE (on Windows Ctrl-C, Ctrl-Break and closing the
  console) delete the temporaries this process is still writing, and end
  it as the signal would have (130 for SIGINT; STATUS_CONTROL_C_EXIT on
  Windows). A signal ignored when the program started (nohup) stays
  ignored. Once, from the program, before any write. }
procedure InstallInterruptCleanup;

const
  { a temporary older than this, of a process that is gone, is a leftover }
  LEFTOVER_AGE = 3600;

{ The temporaries an interrupted run left in the directory `fileName` is
  written to: a SIGKILL, a crash or a power cut, which the handlers above
  cannot see. Only names of PJA's own pattern (.pja-tmp-<pid>-<n>, and the
  .pja-tmp<n> of 0.9.0 and earlier), only regular files (not links nor
  directories), only older than LEFTOVER_AGE, and never of a process that
  is still running. Each directory once per run: '' when it was already
  looked at, or when there is nothing. Otherwise a line to show: what was
  found, or with `clean` what was deleted. Nothing is deleted without
  `clean`. }
function CheckLeftovers(const fileName: RawByteString; clean: Boolean): RawByteString;

{ Exposed for the tests. A name (no directory) of PJA's temporary pattern;
  pid is 0 for the old pattern without one. }
function IsTempName(const name: RawByteString; out pid: Int64): Boolean;
{ The temporary name this process gives its n-th try (no directory). }
function TempName(n: Integer): RawByteString;

implementation

uses
  {$ifdef MSWINDOWS} Windows {$else} BaseUnix, Unix {$ifdef linux}, initc{$endif} {$endif};

function TFsResult.Ok: Boolean; begin Result := error = feNone; end;
function TFsResult.Text: string;
const N: array[TFsError] of string = ('None', 'Io', 'CouldNotKeep', 'NotSynced');
begin
  Result := N[error];
  if error <> feNone then
    if code < 0 then Result := Result + '(-)' else Result := Result + '(' + IntToStr(code) + ')';
end;

function FsFail(e: TFsError; code: LongInt): TFsResult;
begin Result.error := e; Result.code := code; end;

{ ------------------------------------------------------------------------
  System layer. Everything that depends on the platform is here. }

{$ifdef MSWINDOWS}
const
  FILE_SHARE_DELETE_ = $00000004;
function W(const p: RawByteString): UnicodeString;
begin Result := UTF8Decode(p); end;

function IsDirectory(const p: RawByteString): Boolean;
var a: DWORD;
begin
  a := GetFileAttributesW(PWideChar(W(p)));
  Result := (a <> INVALID_FILE_ATTRIBUTES) and ((a and FILE_ATTRIBUTE_DIRECTORY) <> 0);
end;

{ The entry, without following links (GetFileAttributes does not follow them). }
function EntryExists(const p: RawByteString): Boolean;
begin Result := GetFileAttributesW(PWideChar(W(p))) <> INVALID_FILE_ATTRIBUTES; end;

function LastError: LongInt; begin Result := LongInt(GetLastError); end;
const E_NOT_FOUND = ERROR_FILE_NOT_FOUND; E_NOT_FOUND2 = ERROR_PATH_NOT_FOUND;
  { something that is not a folder where one is needed }
  E_NOT_DIR = ERROR_DIRECTORY;
  E_EXISTS = ERROR_FILE_EXISTS;

{ A name the system will not take for its length. Past MAX_PATH Windows
  answers "path not found" (the parent exists by then) or "invalid name". }
function TooLong(code: LongInt): Boolean;
begin
  Result := (code = ERROR_FILENAME_EXCED_RANGE) or (code = ERROR_PATH_NOT_FOUND) or (code = ERROR_INVALID_NAME);
end;

function MakeDir(const p: RawByteString): Boolean;
begin Result := CreateDirectoryW(PWideChar(W(p)), nil); end;
function DeleteEntry(const p: RawByteString): Boolean;
begin Result := DeleteFileW(PWideChar(W(p))); end;
const
  { not in FPC's Windows unit. Microsoft documents it only for a move done
    as a copy and a delete (another volume), which these never are: kept
    for that case, it does not make a rename on the same volume durable.
    There the data is on the disk before the move (SyncFile), so the output
    is whole or absent; its name is left to the file system's journal. }
  MOVEFILE_WRITE_THROUGH_ = $8;
function WriteThrough: DWORD;
begin if SyncToDisk then Result := MOVEFILE_WRITE_THROUGH_ else Result := 0; end;
function RenameEntry(const a, b: RawByteString): Boolean;
begin Result := MoveFileExW(PWideChar(W(a)), PWideChar(W(b)), MOVEFILE_REPLACE_EXISTING or WriteThrough); end;
{ Gives `a` the name `b` only if `b` is free; the same code as CreateNew when
  it is not. }
function MoveNoReplace(const a, b: RawByteString; out code: LongInt): Boolean;
begin
  Result := MoveFileExW(PWideChar(W(a)), PWideChar(W(b)), WriteThrough);
  if Result then begin code := 0; Exit; end;
  code := LastError;
  if code = ERROR_ALREADY_EXISTS then code := ERROR_FILE_EXISTS;
end;

type TFileHandle = THandle;
function CreateNew(const p: RawByteString; out f: TFileHandle): Boolean;
begin
  f := CreateFileW(PWideChar(W(p)), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE_,
                   nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  Result := f <> INVALID_HANDLE_VALUE;
end;
function WriteAll(f: TFileHandle; const data: TBytes): Boolean;
var done: SizeInt; n: DWORD; ask: DWORD;
begin
  done := 0;
  while done < Length(data) do begin
    ask := DWORD(Length(data) - done);
    if ask > $40000000 then ask := $40000000;
    if not WriteFile(f, data[done], ask, n, nil) then Exit(False);
    if n = 0 then begin SetLastError(0); Exit(False); end;   { like write_all: WriteZero, no code }
    Inc(done, n);
  end;
  Result := True;
end;
procedure CloseHandleOf(f: TFileHandle); begin CloseHandle(f); end;
{ The data on the disk, not only in the system's cache. A device that does
  not take it (no buffers to flush) is not an error. }
function SyncFile(f: TFileHandle): Boolean;
var e: DWORD;
begin
  if not SyncToDisk then Exit(True);
  Result := FlushFileBuffers(f);
  if not Result then begin
    e := GetLastError;
    Result := (e = ERROR_INVALID_FUNCTION) or (e = ERROR_NOT_SUPPORTED);
    if not Result then SetLastError(e);
  end;
end;
{ No directory to flush on Windows: Win32 has no fsync of a directory (see
  MOVEFILE_WRITE_THROUGH_ above). }
function SyncDir(const dir: RawByteString; out code: LongInt): Boolean;
begin code := 0; Result := True; end;
function OwnPid: Int64; begin Result := GetCurrentProcessId; end;
{ Alive, or not ours to tell: only a process that is certainly gone says no. }
function PidAlive(pid: Int64): Boolean;
var h: THandle; c: DWORD;
begin
  if (pid <= 0) or (pid > High(DWORD)) then Exit(False);
  h := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, DWORD(pid));
  if h = 0 then Exit(GetLastError <> ERROR_INVALID_PARAMETER);
  Result := not GetExitCodeProcess(h, c) or (c = STILL_ACTIVE);
  CloseHandle(h);
end;

{$else}
const
  {$ifdef linux} O_CLOEXEC_ = $80000; {$else} O_CLOEXEC_ = 0; {$endif}

function IsDirectory(const p: RawByteString): Boolean;
var st: Stat;
begin Result := (Pos(#0, p) = 0) and (fpStat(PChar(p), st) = 0) and fpS_ISDIR(st.st_mode); end;

function EntryExists(const p: RawByteString): Boolean;
var st: Stat;
begin Result := (Pos(#0, p) = 0) and (fpLstat(PChar(p), st) = 0); end;

function LastError: LongInt; begin Result := fpgeterrno; end;
const E_NOT_FOUND = ESysENOENT; E_NOT_FOUND2 = ESysENOENT;
  E_NOT_DIR = ESysENOTDIR;
  E_EXISTS = ESysEEXIST;

function TooLong(code: LongInt): Boolean;
begin Result := code = ESysENAMETOOLONG; end;

function MakeDir(const p: RawByteString): Boolean;
begin Result := fpMkdir(PChar(p), &777) = 0; end;
function DeleteEntry(const p: RawByteString): Boolean;
begin Result := fpUnlink(PChar(p)) = 0; end;
function RenameEntry(const a, b: RawByteString): Boolean;
begin Result := fpRename(PChar(a), PChar(b)) = 0; end;
{$ifdef linux}
{ glibc 2.28 and later: a rename that fails with EEXIST instead of
  replacing (Linux 3.15; FAT, exFAT and the usual file systems take it) }
function renameat2(olddirfd: cint; oldpath: PChar; newdirfd: cint; newpath: PChar; flags: cuint): cint;
  cdecl; external 'c' name 'renameat2';
const
  AT_FDCWD = -100;
  RENAME_NOREPLACE = 1;
{$endif}

{ The temporary takes the name only if it is free. On Linux, renameat2
  with RENAME_NOREPLACE, which FAT and exFAT (camera cards, USB sticks)
  take too. Otherwise link(), which never replaces nor follows a link at
  `b`: EEXIST if the name is taken. A file system without either answers
  something else (link: EPERM on FAT): the caller then writes the old way. }
function MoveNoReplace(const a, b: RawByteString; out code: LongInt): Boolean;
{$ifdef linux} var e: cint; {$endif}
begin
  {$ifdef linux}
  if renameat2(AT_FDCWD, PChar(a), AT_FDCWD, PChar(b), RENAME_NOREPLACE) = 0 then begin
    code := 0;
    Exit(True);
  end;
  e := fpgetCerrno;
  if e = ESysEEXIST then begin code := e; Exit(False); end;
  { ENOSYS (an old kernel) or EINVAL (a file system without it): link }
  {$endif}
  Result := fpLink(PChar(a), PChar(b)) = 0;
  if not Result then begin code := LastError; Exit; end;
  code := 0;
  fpUnlink(PChar(a));
end;

type TFileHandle = cint;
function CreateNew(const p: RawByteString; out f: TFileHandle): Boolean;
begin
  f := fpOpen(PChar(p), O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC_, &666);
  Result := f >= 0;
end;
function WriteAll(f: TFileHandle; const data: TBytes): Boolean;
var done: SizeInt; n: TSsize;
begin
  done := 0;
  while done < Length(data) do begin
    n := fpWrite(f, data[done], Length(data) - done);
    if n < 0 then begin
      if fpgeterrno = ESysEINTR then Continue;
      Exit(False);
    end;
    if n = 0 then begin fpseterrno(0); Exit(False); end;   { like write_all: WriteZero, no code }
    Inc(done, n);
  end;
  Result := True;
end;
procedure CloseHandleOf(f: TFileHandle); begin fpClose(f); end;
{ The data on the disk, not only in the system's cache. A file system that
  cannot (EINVAL: some special ones) is not an error. }
function SyncFile(f: TFileHandle): Boolean;
begin
  if not SyncToDisk then Exit(True);
  repeat
    if fpfsync(f) = 0 then Exit(True);
  until fpgeterrno <> ESysEINTR;
  Result := fpgeterrno = ESysEINVAL;
end;
{ The directory too, after a name was given: without it, after a power cut
  the new name may not be there (or the old file still is). Opened read
  only: O_DIRECTORY is not the same number on every Linux (FPC gives x86's
  everywhere), and a directory that cannot be opened (no read permission)
  is left as it is. EINVAL and EBADF come from file systems that do not
  sync directories. }
function SyncDir(const dir: RawByteString; out code: LongInt): Boolean;
var d: RawByteString; fd: cint;
begin
  code := 0;
  if not SyncToDisk then Exit(True);
  d := dir;
  if d = '' then d := '.';
  fd := fpOpen(PChar(d), O_RDONLY or O_CLOEXEC_);
  if fd < 0 then Exit(True);
  repeat
    Result := fpfsync(fd) = 0;
  until Result or (fpgeterrno <> ESysEINTR);
  if not Result then begin
    code := fpgeterrno;
    Result := (code = ESysEINVAL) or (code = ESysEBADF);
    if Result then code := 0;
  end;
  fpClose(fd);
end;
function OwnPid: Int64; begin Result := fpGetPid; end;
{ kill(pid, 0): ESRCH is the only "gone"; EPERM is a live process of
  another user. pid 1 is asked too: in a container pja itself may be it.
  It answers for this pid namespace only: a directory shared with another
  machine or container is judged against the wrong table (the age is then
  the only guard). }
function PidAlive(pid: Int64): Boolean;
begin
  if (pid <= 0) or (pid > High(LongInt)) then Exit(False);
  if fpKill(TPid(pid), 0) = 0 then Exit(True);
  Result := fpgeterrno <> ESysESRCH;
end;
{$endif}

{ ------------------------------------------------------------------------
  Paths as text. }

{ The path is typed by the user: on Windows it may come with '/' or with '\'. }
function IsSep(c: Char): Boolean; inline;
begin
  {$ifdef MSWINDOWS} Result := (c = '\') or (c = '/'); {$else} Result := c = '/'; {$endif}
end;

{ Root: '/' on Unix; on Windows "C:\", "\\srv\share\", or the same with the
  "\\?\" (or "\\?\UNC\") prefix. }
function IsRoot(const p: RawByteString): Boolean;
{$ifdef MSWINDOWS}
var r: RawByteString; i, n: SizeInt;
begin
  { "Ends in \" is not enough: that way the parent of \\?\C:\a\b came out as
    \\?\C:\a\ (seen on real Windows 10). Root is X:\ or \\srv\share\, with or
    without the \\?\ (or \\?\UNC\) prefix. }
  if (p = '') or not IsSep(p[Length(p)]) then Exit(False);
  if Copy(p, 1, 8) = '\\?\UNC\' then r := '\\' + Copy(p, 9, MaxInt)
  else if Copy(p, 1, 4) = '\\?\' then r := Copy(p, 5, MaxInt)
  else r := p;
  if (Length(r) = 3) and (r[2] = ':') then Exit(True);
  if (Length(r) >= 2) and IsSep(r[1]) and IsSep(r[2]) then begin
    n := 0;
    for i := 3 to Length(r) do if IsSep(r[i]) then Inc(n);
    Exit(n = 2);
  end;
  Result := False;
end;
{$else}
begin
  Result := p = '/';
end;
{$endif}

{ Path::parent: without the last component; False if it already is the root. }
function Parent(const p: RawByteString; out q: RawByteString): Boolean;
var i: SizeInt;
begin
  q := '';
  if IsRoot(p) or (p = '') then Exit(False);
  i := Length(p);
  while (i > 0) and not IsSep(p[i]) do Dec(i);
  if i = 0 then begin q := ''; Exit(True); end;    { "x" -> "" }
  q := Copy(p, 1, i - 1);
  { the root separator stays: "/a" -> "/", "\\?\C:\a" -> "\\?\C:\" }
  if (q = '') or IsRoot(Copy(p, 1, i)) then q := Copy(p, 1, i);
  { This Result was missing: the function returned whatever was left in the
    register. In the differential against the Rust it gave "Io(-)" in 1 of
    every ~10 runs. FPC does not warn if some path does Exit(value):
    results.py does. }
  Result := True;
end;

{ ------------------------------------------------------------------------ }

{ fs::create_dir_all, the same algorithm: mkdir; if the parent is missing,
  create the parent and retry; if mkdir fails but it already is a directory,
  that is enough. }
function MakeDirs(const p: RawByteString; out code: LongInt): Boolean;
var q: RawByteString;
begin
  code := 0;
  if p = '' then Exit(True);
  if MakeDir(p) then Exit(True);
  code := LastError;
  if (code <> E_NOT_FOUND) and (code <> E_NOT_FOUND2) then begin
    Result := IsDirectory(p);
    { the name is taken by something that is not a folder: say that, not
      "it exists" }
    if Result then code := 0 else if EntryExists(p) then code := E_NOT_DIR;
    Exit;
  end;
  if not Parent(p, q) then begin code := -1; Exit(False); end;
  if not MakeDirs(q, code) then Exit(False);
  if MakeDir(p) then begin code := 0; Exit(True); end;
  code := LastError;
  Result := IsDirectory(p);
  if Result then code := 0 else if EntryExists(p) then code := E_NOT_DIR;
end;

{ The directory part of `fileName`, with its separator ('' for a bare
  name): what a name in the same directory starts with. }
function DirPrefix(const fileName: RawByteString): RawByteString;
var i: SizeInt;
begin
  i := Length(fileName);
  {$ifdef MSWINDOWS}
  while (i > 0) and not IsSep(fileName[i]) and (fileName[i] <> ':') do Dec(i);   { "C:x": the drive's current directory }
  {$else}
  while (i > 0) and not IsSep(fileName[i]) do Dec(i);
  {$endif}
  Result := Copy(fileName, 1, i);
end;

{ First free `<path>.corrupt[.N]`, looking at the entry and not at what it
  points to. }
function FreeCorruptPath(const fileName: RawByteString; out r: RawByteString): Boolean;
var n: Integer;
begin
  r := fileName + '.corrupt';
  if not EntryExists(r) then Exit(True);
  for n := 1 to 999 do begin
    r := fileName + '.corrupt.' + IntToStr(n);
    if not EntryExists(r) then Exit(True);
  end;
  r := '';
  Result := False;
end;

{ ------------------------------------------------------------------------
  The names being written, for the interrupt handler. A fixed table that
  the handler only reads, deleting what it names: no allocation, no lock.
  A slot is 0 free, 1 being filled by the thread that took it, 2 live,
  3 taken by the handler. A slot's buffer is its own for good, grown only
  by its owner in state 1: the handler never reads one being freed. }

const
  { a thread writes one name at a time, and -th is at most 64 }
  LIVE_SLOTS = 128;
type
  {$ifdef MSWINDOWS} PLiveName = PWideChar; {$else} PLiveName = PAnsiChar; {$endif}
  TLiveSlot = record
    state: LongInt;
    name: PLiveName;
    cap: SizeInt;
  end;
var
  live: array[0..LIVE_SLOTS - 1] of TLiveSlot;
  { set by the handler before it looks at the table }
  dying: LongInt;

{ The handler is deleting what this thread writes, and the process ends:
  nothing more to do here. }
procedure AwaitDeath;
begin
  repeat Sleep(1000) until False;
end;

{ -1 when the table is full: the name is written as before, only without
  the handler's help. `created`: the file is already there, made by this
  thread; if the handler may have passed the slot, it is deleted here. }
function RegisterLive(const path: RawByteString; created: Boolean): Integer;
var i: Integer; n: SizeInt; {$ifdef MSWINDOWS} u: UnicodeString; {$endif}
begin
  {$ifdef MSWINDOWS} u := W(path); n := Length(u); {$else} n := Length(path); {$endif}
  for i := 0 to LIVE_SLOTS - 1 do
    if InterlockedCompareExchange(live[i].state, 1, 0) = 0 then begin
      if live[i].cap < n + 1 then begin
        ReallocMem(live[i].name, (n + 1) * SizeOf(live[i].name^));
        live[i].cap := n + 1;
      end;
      {$ifdef MSWINDOWS}
      if n > 0 then Move(u[1], live[i].name^, n * SizeOf(WideChar));
      {$else}
      if n > 0 then Move(path[1], live[i].name^, n);
      {$endif}
      live[i].name[n] := #0;
      InterlockedExchange(live[i].state, 2);
      { the handler started meanwhile, and may have passed this slot }
      if InterlockedCompareExchange(dying, 0, 0) <> 0 then begin
        if created then DeleteEntry(path);
        AwaitDeath;
      end;
      Exit(i);
    end;
  Result := -1;
end;

procedure ReleaseLive(slot: Integer);
begin
  if slot < 0 then Exit;
  { not 2: the handler took it, and the process is ending }
  if InterlockedCompareExchange(live[slot].state, 0, 2) <> 2 then AwaitDeath;
end;

{ Only what is async-signal-safe: atomics and unlink (DeleteFileW). }
procedure DeleteLive;
var i: Integer;
begin
  InterlockedExchange(dying, 1);
  for i := 0 to LIVE_SLOTS - 1 do
    if InterlockedCompareExchange(live[i].state, 3, 2) = 2 then
      {$ifdef MSWINDOWS} DeleteFileW(live[i].name); {$else} fpUnlink(live[i].name); {$endif}
end;

{$ifdef MSWINDOWS}
const
  { what Windows ends a console program with on Ctrl-C }
  STATUS_CONTROL_C_EXIT_ = $C000013A;

{ Runs in a thread of its own, while the others go on: the table's states
  keep them apart. }
function OnConsoleEvent(ev: DWORD): WINBOOL; stdcall;
begin
  case ev of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT: begin
      DeleteLive;
      ExitProcess(UINT(STATUS_CONTROL_C_EXIT_));
    end;
  end;
  Result := False;
end;

procedure InstallInterruptCleanup;
begin
  { a console that ignores Ctrl-C (a process group started that way) never
    sends it here }
  SetConsoleCtrlHandler(@OnConsoleEvent, True);
end;
{$else}
{ Deletes, then ends the process by the same signal, its default action
  back: the parent sees "killed by SIGINT" (a shell: 130), and a loop in a
  script stops. If that signal were somehow held, exit with 128 + sig. }
procedure OnSignal(sig: LongInt; si: PSigInfo; ctx: PSigContext); cdecl;
var act: SigActionRec; mask: TSigSet;
begin
  DeleteLive;
  FillChar(act, SizeOf(act), 0);
  act.sa_handler := SigActionHandler_t(Pointer(PtrUInt(SIG_DFL)));
  fpSigAction(sig, @act, nil);
  fpSigEmptySet(mask);
  fpSigAddSet(mask, sig);
  fpSigProcMask(SIG_UNBLOCK, @mask, nil);
  fpKill(fpGetPid, sig);
  fpExit(128 + sig);
end;

procedure InstallInterruptCleanup;
  { SIGPIPE: `pja x ... | head`, the reader gone while workers write }
const SIGS: array[0..3] of cint = (SIGINT, SIGTERM, SIGHUP, SIGPIPE);
var act, old: SigActionRec; i: Integer;
begin
  FillChar(act, SizeOf(act), 0);
  act.sa_handler := SigActionHandler_t(@OnSignal);
  fpSigEmptySet(act.sa_mask);
  { one handler at a time: a second signal waits }
  for i := 0 to High(SIGS) do fpSigAddSet(act.sa_mask, SIGS[i]);
  act.sa_flags := SA_SIGINFO or SA_RESTART;
  for i := 0 to High(SIGS) do begin
    FillChar(old, SizeOf(old), 0);
    if fpSigAction(SIGS[i], nil, @old) <> 0 then Continue;
    { ignored on purpose by whoever started us (nohup, a background job) }
    if Pointer(old.sa_handler) = Pointer(PtrUInt(SIG_IGN)) then Continue;
    fpSigAction(SIGS[i], @act, nil);
  end;
end;
{$endif}

{ ------------------------------------------------------------------------ }

{ Creates `path` (never opens an existing one nor follows links), writes
  everything and flushes it to the disk; if any of that fails, deletes
  what it created. While it is written the name is in the handler's table
  (slot, for the caller to release): a temporary of ours (`temp`, our pid
  in its name) from before it is created, so no instant is left uncovered;
  any other name only once created, so the handler never deletes a file
  that was already there. }
function CreateAndWrite(const path: RawByteString; const data: TBytes; temp: Boolean;
                        out slot: Integer; out code: LongInt): Boolean;
var f: TFileHandle;
begin
  code := 0; slot := -1;
  if temp then slot := RegisterLive(path, False);
  { If it could not be created there is nothing of ours to delete. }
  if not CreateNew(path, f) then begin
    code := LastError;
    ReleaseLive(slot); slot := -1;
    Exit(False);
  end;
  if not temp then slot := RegisterLive(path, True);
  if not WriteAll(f, data) or not SyncFile(f) then begin
    code := LastError;
    if code = 0 then code := -1;
    CloseHandleOf(f);
    DeleteEntry(path);                   { a half-done write is not left lying around }
    ReleaseLive(slot); slot := -1;
    Exit(False);
  end;
  CloseHandleOf(f);
  Result := True;
end;

{ A file that is not a temporary: written and flushed, in place. False
  when nothing is left; the caller flushes the directory once it is there. }
function WriteFinal(const path: RawByteString; const data: TBytes; out code: LongInt): Boolean;
var slot: Integer;
begin
  if not CreateAndWrite(path, data, False, slot, code) then Exit(False);
  ReleaseLive(slot);
  Result := True;
end;

function TempName(n: Integer): RawByteString;
begin
  Result := '.pja-tmp-' + IntToStr(OwnPid) + '-' + IntToStr(n);
end;

{ 1 to maxLen decimal digits, without a leading zero (but "0") }
function Digits(const s: RawByteString; maxLen: Integer): Boolean;
var i: SizeInt;
begin
  Result := (Length(s) >= 1) and (Length(s) <= maxLen) and ((Length(s) = 1) or (s[1] <> '0'));
  if Result then
    for i := 1 to Length(s) do if not (s[i] in ['0'..'9']) then Exit(False);
end;

function IsTempName(const name: RawByteString; out pid: Int64): Boolean;
var rest: RawByteString; k: SizeInt;
begin
  pid := 0; Result := False;
  if Copy(name, 1, 8) <> '.pja-tmp' then Exit;
  rest := Copy(name, 9, MaxInt);
  if (rest = '') or (rest[1] <> '-') then Exit(Digits(rest, 3));     { 0.9.0 and earlier }
  Delete(rest, 1, 1);
  k := Pos('-', rest);
  if (k = 0) or not Digits(Copy(rest, 1, k - 1), 10) or not Digits(Copy(rest, k + 1, MaxInt), 3) then Exit;
  pid := StrToInt64(Copy(rest, 1, k - 1));
  Result := (pid >= 1) and (pid <= High(LongWord));
end;

{ Writes `data` to a new temporary in the directory of `fileName`, under a
  short name of its own: <name>.pja-tmpN went over NAME_MAX (or MAX_PATH)
  with a long name, where the name itself still fit. The pid in the name
  tells a live run's temporaries from a dead one's (CheckLeftovers). }
function WriteTemp(const fileName: RawByteString; const data: TBytes; out tmp: RawByteString;
                   out slot: Integer; out code: LongInt): Boolean;
var n: Integer;
begin
  slot := -1;
  for n := 0 to 999 do begin
    tmp := DirPrefix(fileName) + TempName(n);
    if CreateAndWrite(tmp, data, True, slot, code) then Exit(True);
    { a real failure, not a taken name. EEXIST counts as taken even if it is
      gone by now: another job of the run gave it its name meanwhile. }
    if (code <> E_EXISTS) and not EntryExists(tmp) then begin tmp := ''; Exit(False); end;
  end;
  tmp := ''; code := -1;
  Result := False;
end;

function WriteVerified(const fileName: RawByteString; const data: TBytes; const expected: THash16;
                       onMismatch: TOnMismatch; overwrite: Boolean; out outcome: TOutcome): TFsResult;
var p, other, tmp: RawByteString; code: LongInt; actual: THash16; slot: Integer;
begin
  outcome.kind := ocVerified; outcome.path := '';
  FillChar(outcome.expected, SizeOf(outcome.expected), 0); FillChar(outcome.actual, SizeOf(outcome.actual), 0);
  if Pos(#0, fileName) > 0 then Exit(FsFail(feIo, -1));
  if Parent(fileName, p) then
    if not MakeDirs(p, code) then Exit(FsFail(feIo, code));

  { The hash is of the data about to be written: it is checked BEFORE. What
    does not match is never written under its name, not even for an instant. }
  actual := Blake3_128(data);
  if not CompareMem(@actual[0], @expected[0], SizeOf(THash16)) then begin
    outcome.expected := expected; outcome.actual := actual;
    if onMismatch = omDelete then begin
      outcome.kind := ocDeleted;         { "deleted": nothing is left, because nothing was written }
      Exit(FsFail(feNone, 0));
    end;
    if not FreeCorruptPath(fileName, other) then Exit(FsFail(feCouldNotKeep, -1));
    if not WriteFinal(other, data, code) then begin
      { <name>.corrupt does not fit where <name> did: a short one beside it }
      if not TooLong(code) then Exit(FsFail(feCouldNotKeep, code));
      if not FreeCorruptPath(DirPrefix(fileName) + 'pja', other) then Exit(FsFail(feCouldNotKeep, -1));
      if not WriteFinal(other, data, code) then Exit(FsFail(feCouldNotKeep, code));
    end;
    outcome.kind := ocKept; outcome.path := other;
    if not SyncDir(DirPrefix(other), code) then Exit(FsFail(feNotSynced, code));
    Exit(FsFail(feNone, 0));
  end;

  { Both ways go through a new temporary in the same directory, and only
    once it is fully written AND on the disk does it take the name: a run
    cut short (Ctrl-C, a kill, a full disk, a power cut) leaves at most a
    .pja-tmp-<pid>-<n>, never a truncated or empty file under the output's
    name. The directory is flushed once the name is given. }
  if not overwrite then begin
    { taken already: nothing to write (and the same code as before) }
    if EntryExists(fileName) then Exit(FsFail(feIo, E_EXISTS));
    if not WriteTemp(fileName, data, tmp, slot, code) then Exit(FsFail(feIo, code));
    { The name is given only if it is still free: no rename on top, so
      whatever took it meanwhile (a link too) stays as it was. }
    if MoveNoReplace(tmp, fileName, code) then ReleaseLive(slot)
    else begin
      DeleteEntry(tmp);
      ReleaseLive(slot);
      if code = E_EXISTS then Exit(FsFail(feIo, code));
      { no hard links here (FAT): created in place, as before }
      if not WriteFinal(fileName, data, code) then Exit(FsFail(feIo, code));
    end;
    outcome.path := fileName;
    { the file is in place by now: a failure here is not "could not write" }
    if not SyncDir(DirPrefix(fileName), code) then Exit(FsFail(feNotSynced, code));
    Exit(FsFail(feNone, 0));
  end;

  { Overwrite: once fully written, the temporary is renamed over the target.
    What was there stays intact if something fails before, and rename
    replaces the ENTRY: it does not write through a symbolic or hard link
    with that name. Before, the target was deleted first: an `x -f` of a
    file that did not verify destroyed the JPEG the user already had
    (measured from the CLI, 12/10/2026). }
  if not WriteTemp(fileName, data, tmp, slot, code) then Exit(FsFail(feIo, code));
  if not RenameEntry(tmp, fileName) then begin
    code := LastError;
    DeleteEntry(tmp);
    ReleaseLive(slot);
    Exit(FsFail(feIo, code));
  end;
  ReleaseLive(slot);
  outcome.path := fileName;
  if not SyncDir(DirPrefix(fileName), code) then Exit(FsFail(feNotSynced, code));
  Result := FsFail(feNone, 0);
end;

{ ------------------------------------------------------------------------
  Leftovers of an interrupted run. }

type TNames = array of RawByteString;

var
  scanLock: TRTLCriticalSection;
  scanned: TNames;

{ True the first time a directory is asked for in this run }
function FirstLook(const dir: RawByteString): Boolean;
var i: SizeInt;
begin
  EnterCriticalSection(scanLock);
  try
    for i := 0 to High(scanned) do if scanned[i] = dir then Exit(False);
    SetLength(scanned, Length(scanned) + 1);
    scanned[High(scanned)] := dir;
    Result := True;
  finally
    LeaveCriticalSection(scanLock);
  end;
end;

procedure AddName(var names: TNames; const s: RawByteString);
begin
  SetLength(names, Length(names) + 1);
  names[High(names)] := s;
end;

{ A temporary of a process that is not this one and is gone (the old
  pattern has no pid: its age is enough) }
function Orphan(pid: Int64): Boolean;
begin
  Result := (pid = 0) or ((pid <> OwnPid) and not PidAlive(pid));
end;

{$ifdef MSWINDOWS}
const FILE_ATTRIBUTE_REPARSE_POINT_ = $400;
function ListLeftovers(const dir: RawByteString): TNames;
var h: THandle; fd: WIN32_FIND_DATAW; name: RawByteString; pid: Int64; now: TFileTime; t, n: QWord;
begin
  Result := nil;
  h := FindFirstFileW(PWideChar(W(dir + '*')), fd);
  if h = INVALID_HANDLE_VALUE then Exit;
  GetSystemTimeAsFileTime(now);
  n := (QWord(now.dwHighDateTime) shl 32) or now.dwLowDateTime;
  repeat
    name := UTF8Encode(UnicodeString(PWideChar(@fd.cFileName[0])));
    if not IsTempName(name, pid) then Continue;
    { a regular file: not a folder, not a link (a reparse point) }
    if (fd.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT_)) <> 0 then Continue;
    t := (QWord(fd.ftLastWriteTime.dwHighDateTime) shl 32) or fd.ftLastWriteTime.dwLowDateTime;
    if (t > n) or (n - t < QWord(LEFTOVER_AGE) * 10000000) then Continue;
    if Orphan(pid) then AddName(Result, dir + name);
  until not FindNextFileW(h, fd);
  Windows.FindClose(h);
end;
{$else}
function ListLeftovers(const dir: RawByteString): TNames;
var d: PDir; e: PDirent; name, path: RawByteString; st: Stat; pid: Int64; now: Int64;
begin
  Result := nil;
  if dir = '' then d := fpOpendir(PChar('.')) else d := fpOpendir(PChar(dir));
  if d = nil then Exit;
  now := fpTime;
  repeat
    e := fpReaddir(d^);
    if e = nil then Break;
    name := StrPas(PChar(@e^.d_name[0]));
    if not IsTempName(name, pid) then Continue;
    path := dir + name;
    { a regular file, by the entry: a link is neither followed nor deleted }
    if (fpLstat(PChar(path), st) <> 0) or not fpS_ISREG(st.st_mode) then Continue;
    if Int64(st.st_mtime) > now - LEFTOVER_AGE then Continue;
    if Orphan(pid) then AddName(Result, path);
  until False;
  fpClosedir(d^);
end;
{$endif}

function CheckLeftovers(const fileName: RawByteString; clean: Boolean): RawByteString;
var dir, list, failed: RawByteString; names: TNames; i, gone: Integer; code: LongInt;

  function Count(n: Integer): RawByteString;
  begin
    if n = 1 then Result := '1 leftover temporary' else Result := IntToStr(n) + ' leftover temporaries';
  end;

begin
  Result := '';
  if Pos(#0, fileName) > 0 then Exit;
  dir := DirPrefix(fileName);
  if not FirstLook(dir) then Exit;
  names := ListLeftovers(dir);
  if Length(names) = 0 then Exit;
  if not clean then begin
    list := '';
    for i := 0 to High(names) do
      if i < 3 then begin
        if i > 0 then list := list + ', ';
        list := list + names[i];
      end;
    if Length(names) > 3 then list := list + ' and ' + IntToStr(Length(names) - 3) + ' more';
    if Length(names) = 1 then list := list + '; --clean-temps deletes it'
    else list := list + '; --clean-temps deletes them';
    Exit('found ' + Count(Length(names)) + ' of an interrupted run: ' + list);
  end;
  gone := 0; failed := ''; code := 0;
  for i := 0 to High(names) do
    if DeleteEntry(names[i]) or (LastError = E_NOT_FOUND) then Inc(gone)  { gone: another run cleaned it }
    else if failed = '' then begin code := LastError; failed := names[i]; end;
  Result := 'deleted ' + Count(gone) + ' of an interrupted run';
  if dir <> '' then Result := Result + ' in ' + dir;
  if failed <> '' then
    Result := Result + '; could not delete ' + IntToStr(Length(names) - gone) + ', ' + failed + ': ' +
              SysErrorMessage(code);
end;

initialization
  InitCriticalSection(scanLock);
finalization
  DoneCriticalSection(scanLock);
end.
