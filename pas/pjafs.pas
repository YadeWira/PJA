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
  name without replacing anything (MoveFileExW without REPLACE_EXISTING). }
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
              feCouldNotKeep);
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
  temporary (.pja-tmpN in the same directory) and given the name only once
  complete: an existing file is never opened, and links are not followed.
  Without `overwrite` the name is only taken if free; with it, the temporary
  is renamed over the target: what was there is only replaced by something
  that verified. If the hash does not match, nothing is written under that
  name (with omKeep, it stays as <file>.corrupt[.N], or pja.corrupt[.N]
  beside it if that name is too long). }
function WriteVerified(const fileName: RawByteString; const data: TBytes; const expected: THash16;
                       onMismatch: TOnMismatch; overwrite: Boolean; out outcome: TOutcome): TFsResult;

{ Exposed for the tests. Path::parent; False at the root or with an empty path. }
function Parent(const p: RawByteString; out q: RawByteString): Boolean;

implementation

uses
  {$ifdef MSWINDOWS} Windows {$else} BaseUnix {$endif};

function TFsResult.Ok: Boolean; begin Result := error = feNone; end;
function TFsResult.Text: string;
const N: array[TFsError] of string = ('None', 'Io', 'CouldNotKeep');
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
function RenameEntry(const a, b: RawByteString): Boolean;
begin Result := MoveFileExW(PWideChar(W(a)), PWideChar(W(b)), MOVEFILE_REPLACE_EXISTING); end;
{ Gives `a` the name `b` only if `b` is free; the same code as CreateNew when
  it is not. }
function MoveNoReplace(const a, b: RawByteString; out code: LongInt): Boolean;
begin
  Result := MoveFileExW(PWideChar(W(a)), PWideChar(W(b)), 0);
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
{ link() never replaces nor follows a link at `b`: EEXIST if the name is
  taken. A file system without hard links answers something else (EPERM on
  FAT): the caller then writes the old way. }
function MoveNoReplace(const a, b: RawByteString; out code: LongInt): Boolean;
begin
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

{ Creates `path` (never opens an existing one nor follows links) and writes
  everything; if the write fails, deletes what it created. }
function CreateAndWrite(const path: RawByteString; const data: TBytes; out code: LongInt): Boolean;
var f: TFileHandle;
begin
  code := 0;
  { If it could not be created there is nothing of ours to delete. }
  if not CreateNew(path, f) then begin code := LastError; Exit(False); end;
  if not WriteAll(f, data) then begin
    code := LastError;
    if code = 0 then code := -1;
    CloseHandleOf(f);
    DeleteEntry(path);                   { a half-done write is not left lying around }
    Exit(False);
  end;
  CloseHandleOf(f);
  Result := True;
end;

{ Writes `data` to a new temporary in the directory of `fileName`, under a
  short name of its own: <name>.pja-tmpN went over NAME_MAX (or MAX_PATH)
  with a long name, where the name itself still fit. }
function WriteTemp(const fileName: RawByteString; const data: TBytes; out tmp: RawByteString;
                   out code: LongInt): Boolean;
var n: Integer;
begin
  for n := 0 to 999 do begin
    tmp := DirPrefix(fileName) + '.pja-tmp' + IntToStr(n);
    if CreateAndWrite(tmp, data, code) then Exit(True);
    { a real failure, not a taken name. EEXIST counts as taken even if it is
      gone by now: another job of the run gave it its name meanwhile. }
    if (code <> E_EXISTS) and not EntryExists(tmp) then begin tmp := ''; Exit(False); end;
  end;
  tmp := ''; code := -1;
  Result := False;
end;

function WriteVerified(const fileName: RawByteString; const data: TBytes; const expected: THash16;
                       onMismatch: TOnMismatch; overwrite: Boolean; out outcome: TOutcome): TFsResult;
var p, other, tmp: RawByteString; code: LongInt; actual: THash16;
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
    if not CreateAndWrite(other, data, code) then begin
      { <name>.corrupt does not fit where <name> did: a short one beside it }
      if not TooLong(code) then Exit(FsFail(feCouldNotKeep, code));
      if not FreeCorruptPath(DirPrefix(fileName) + 'pja', other) then Exit(FsFail(feCouldNotKeep, -1));
      if not CreateAndWrite(other, data, code) then Exit(FsFail(feCouldNotKeep, code));
    end;
    outcome.kind := ocKept; outcome.path := other;
    Exit(FsFail(feNone, 0));
  end;

  { Both ways go through a new temporary in the same directory, and only
    once it is fully written does it take the name: a run cut short (Ctrl-C,
    a kill, a full disk) leaves at most a .pja-tmpN, never a truncated file
    under the output's name. }
  if not overwrite then begin
    { taken already: nothing to write (and the same code as before) }
    if EntryExists(fileName) then Exit(FsFail(feIo, E_EXISTS));
    if not WriteTemp(fileName, data, tmp, code) then Exit(FsFail(feIo, code));
    { The name is given only if it is still free: no rename on top, so
      whatever took it meanwhile (a link too) stays as it was. }
    if not MoveNoReplace(tmp, fileName, code) then begin
      DeleteEntry(tmp);
      if code = E_EXISTS then Exit(FsFail(feIo, code));
      { no hard links here (FAT): created in place, as before }
      if not CreateAndWrite(fileName, data, code) then Exit(FsFail(feIo, code));
    end;
    outcome.path := fileName;
    Exit(FsFail(feNone, 0));
  end;

  { Overwrite: once fully written, the temporary is renamed over the target.
    What was there stays intact if something fails before, and rename
    replaces the ENTRY: it does not write through a symbolic or hard link
    with that name. Before, the target was deleted first: an `x -f` of a
    file that did not verify destroyed the JPEG the user already had
    (measured from the CLI, 12/10/2026). }
  if not WriteTemp(fileName, data, tmp, code) then Exit(FsFail(feIo, code));
  if not RenameEntry(tmp, fileName) then begin
    code := LastError;
    DeleteEntry(tmp);
    Exit(FsFail(feIo, code));
  end;
  outcome.path := fileName;
  Result := FsFail(feNone, 0);
end;

end.
