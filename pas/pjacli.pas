{ The pja command: JPEG, JPEG-LS and JPEG 2000 files to .pja and back.
  doc/CLI.md has the switches and the reasons behind them.

    pja a [options] FILE...     compress: photo.jpg -> photo.pja
    pja x [options] FILE...     extract:  photo.pja -> photo.jpg (or .jls, .mpo, .jp2...)
    pja list FILE...            what each .pja holds
    pja t FILE...               test: extract and verify, write nothing
    pja info FILE...            the structure of each file, and what PJA does with it
    pja report [FILE]           a bug report, and a link to open an issue with it
    pja bench FILE...           how fast this machine compresses and extracts them
    pja selftest                the samples inside the binary, on every SIMD path
    pja --version               the build, the system and the SIMD path

  Nothing is written under an output's name unless it verified: `a` checks
  that its stream decompresses to the input, `x` that the size and the hash
  match. An existing output is only replaced with -f. }
program pjacli;

{$I pja.inc}
{$ifopt R-}{$fatal pjacli: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjacli: overflow checks ($Q+) are mandatory}{$endif}

uses
  {$ifdef UNIX} cthreads, BaseUnix, {$endif}
  {$ifdef MSWINDOWS} Windows, {$endif}
  SysUtils, Classes, pjablake3, pjaformat, pjacodec, pjajpeg, pjajls, pjapack, pjafs, pjacpu, pjav7, pjaj2km, pjamodel, pjaj2k, pjathread,
  { the commands for reporting and checking (doc/CLI.md); each format's
    info provider registers itself }
  pjastage, pjainfo, pjainfojpeg, pjainfoj2k, pjainfopja, pjasysinfo, pjareport, pjabench, pjaselftest;

const
  DEFAULT_MAX_OUTPUT = 256 * 1024 * 1024;
  { the largest input read whole into memory }
  MAX_INPUT = QWord(1) shl 31;

type
  TCommand = (cmNone, cmCompress, cmExtract, cmList, cmTest, cmInfo, cmReport, cmBench, cmSelftest);

var
  command: TCommand;
  inputs: TStringList;
  outArg: string;          { -o: a name, or a directory }
  outDir: string;          { --output-dir }
  force, keepCorrupt, dryRun, quiet, fastModel, noVerify, cleanTemps: Boolean;
  threads: Integer;
  { --stats, --json; report's --with-file; bench's -r }
  stats, jsonOut, withFile: Boolean;
  runs: Integer;
  runsGiven: Boolean;
  { -th or --threads given }
  thGiven: Boolean;
  { --cpu }
  cpuGiven: Boolean;
  cpuWanted: TCpuPath;
  { files that met a bug (an exception that is not about the file) }
  bugs: Integer;
  bugFile: string;
  maxOutput: QWord;
  errors: Integer;
  { threads per file: what is left of -th once the files are shared out }
  bandThreads: Integer;

type
  { One input: what it printed and whether it failed. Files are processed
    in parallel, and their lines come out in the order of the inputs. }
  TFileJob = record
    name, outText, errText: string;
    index: Integer;
    failed, done: Boolean;
    { an exception that is a bug in PJA, not something about the file }
    bug: Boolean;
    { --json: the object of this file; errors: what failed, for it }
    node: TInfoNode;
    errors: string;
    { the bytes read and written (the summary of --stats and --json) }
    inBytes, outBytes: Int64;
  end;
  PFileJob = ^TFileJob;

threadvar
  CurJob: PFileJob;

var
  jobs: array of TFileJob;

var
  { the arguments, in UTF-8 on every system }
  args: array of string;

{$ifdef MSWINDOWS}
function CommandLineToArgvW(cmd: PWideChar; out n: Integer): PPWideChar; stdcall; external 'shell32.dll';

{ ParamStr goes through the ANSI code page on Windows, and a name like
  "fotoñandú.jpg" does not survive it: the arguments are read in UTF-16
  and kept in UTF-8, the code page the whole program then runs in (so the
  RTL's file functions and pjafs open the right file). }
procedure ReadArgs;
var w: PPWideChar; n, i: Integer;
begin
  DefaultSystemCodePage := CP_UTF8;
  DefaultFileSystemCodePage := CP_UTF8;
  w := CommandLineToArgvW(GetCommandLineW, n);
  args := nil;
  SetLength(args, n);
  for i := 0 to n - 1 do args[i] := UTF8Encode(UnicodeString(w[i]));
  LocalFree(HLOCAL(w));
end;
{ cmd passes a pattern such as *.jpg as it is (Windows leaves that to each
  program): an input with * or ? in its name becomes the files that match,
  in order of name; the folder part is taken as written. A pattern that
  matches nothing stays, and fails as such (ReadWhole). }
procedure ExpandWildcards;
var all, found: TStringList; i: Integer; a, dir: string; sr: TUnicodeSearchRec;
begin
  all := TStringList.Create;
  found := TStringList.Create;
  for i := 0 to inputs.Count - 1 do begin
    a := inputs[i];
    if LastDelimiter('*?', a) <= LastDelimiter('\/:', a) then begin all.Add(a); Continue; end;
    dir := Copy(a, 1, LastDelimiter('\/:', a));
    found.Clear;
    if FindFirst(UnicodeString(UTF8Decode(a)), faAnyFile, sr) = 0 then begin
      repeat
        if sr.Attr and faDirectory = 0 then found.Add(dir + UTF8Encode(sr.Name));
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    if found.Count = 0 then all.Add(a)
    else begin
      found.Sort;
      all.AddStrings(found);
    end;
  end;
  found.Free;
  inputs.Free;
  inputs := all;
end;
{$else}
procedure ReadArgs;
var i: Integer;
begin
  args := nil;
  SetLength(args, ParamCount + 1);
  for i := 0 to ParamCount do args[i] := ParamStr(i);
end;
{$endif}

function ArgCount: Integer;
begin Result := High(args); end;

procedure Fail(const msg: string);
begin
  CurJob^.failed := True;
  CurJob^.errText := CurJob^.errText + 'pja: ' + msg + LineEnding;
  if CurJob^.errors <> '' then CurJob^.errors := CurJob^.errors + '; ';
  CurJob^.errors := CurJob^.errors + msg;
end;

{ a line for people: --json prints the file's object instead }
procedure Say(const line: string);
begin
  if jsonOut then Exit;
  CurJob^.outText := CurJob^.outText + line + LineEnding;
end;

{ a field of the file's --json object }
function JobNode: TInfoNode;
begin
  Result := CurJob^.node;
end;

{ an exception about the file or the system (a read, a write, memory),
  not a bug in PJA }
function NotABug(e: Exception): Boolean;
begin
  Result := (e is EInOutError) or (e is EStreamError) or (e is EOSError) or (e is EOutOfMemory);
end;

{ What could not be written to the output (a full disk, a closed pipe):
  said once, and what is still in the buffer dropped, or the RTL would
  fail on it again at the end with a runtime error }
procedure OutputFailed(const why: string);
begin
  TextRec(Output).BufPos := 0;
  InOutRes := 0;
  Writeln(StdErr, 'pja: could not write the output: ', why);
end;

{ The end: the output flushed first, so that a write that fails says so
  and ends with 1 (not a bug, and not 0) }
procedure Finish(code: Integer);
begin
  try
    Flush(Output);
  except
    on e: Exception do begin
      OutputFailed(e.Message);
      if code = 0 then code := 1;
    end;
  end;
  Halt(code);
end;

procedure Usage(code: Integer);
begin
  Writeln('pja ', PJA_VERSION, ' - lossless recompression of JPEG, JPEG-LS and JPEG 2000 files');
  Writeln;
  Writeln('usage: pja a [options] FILE...     compress to .pja');
  Writeln('       pja x [options] FILE...     extract from .pja');
  Writeln('       pja list FILE...            show what each .pja holds');
  Writeln('       pja t FILE...               test each .pja: extract and verify, write nothing');
  Writeln('       pja info FILE...            the structure of each file, and what PJA does with it');
  Writeln('       pja report [FILE] [-o REPORT.txt] [--with-file]');
  Writeln('                                   a bug report (no pixels, no metadata contents) and');
  Writeln('                                   a link to open an issue with it');
  Writeln('       pja bench FILE... [-r N]    time a, a --no-verify and x (best of N runs)');
  Writeln('       pja selftest                the samples inside pja, on every SIMD path here');
  Writeln('       pja --version, -V           the build, the system and the SIMD path');
  Writeln;
  Writeln('  -o PATH              output name (one input), or directory (ends in / or exists)');
  Writeln('  --output-dir=DIR     output directory');
  Writeln('  -f, --force          replace an existing output (only with something that verified)');
  Writeln('  -th N, --threads=N   threads (default: the processors, up to 8): several');
  Writeln('                       files at once, and what is left to each file''s bands');
  Writeln('  --max-output=SIZE    x: refuse a declared original above SIZE (256M; 0 = no limit)');
  Writeln('  --keep-corrupt       x: keep output that does not verify as NAME.corrupt');
  Writeln('  --fast               a: accepted for older scripts; it changes nothing, the');
  Writeln('                       default model is as fast since 0.1.0 (x needs no switch)');
  Writeln('  --no-verify          a: do not decompress the stream to check it before writing:');
  Writeln('                       about twice as fast, but a codec bug would only show when');
  Writeln('                       extracting (the hash catches it then). The JPEG''s own check');
  Writeln('                       still runs');
  Writeln('  --no-sync            do not wait for each output to reach the disk: a few');
  Writeln('                       percent faster, but a power cut may leave it empty');
  Writeln('  --clean-temps        delete the temporaries an interrupted run left where');
  Writeln('                       this one writes (only PJA''s, old, of no live process)');
  Writeln('  -n, --dry-run        do everything but write');
  Writeln('  -q, --quiet          only errors');
  Writeln('  --stats              a, x, t: where each file''s time went, threads and bands');
  Writeln('  --json               a, x, t, info, list: a JSON object per file, then a summary');
  Writeln('  -r N                 bench: runs of each, the best counts (default 3)');
  Writeln('  --cpu=PATH           the model''s SIMD path: plain, sse41 or avx2 (same output)');
  Writeln('  --                   the rest are files');
  Writeln;
  Writeln('exit status: 0 all went through, 1 a file failed, 2 usage error, 3 a bug in PJA');
  Writeln('bugs: pja report FILE, then ', ISSUES_URL);
  Finish(code);
end;

procedure UsageError(const msg: string);
begin
  Writeln(StdErr, 'pja: ', msg);
  Writeln(StdErr, 'pja: see pja --help');
  Halt(2);
end;

{ "256M", "1G", "1000K", "12345"; False if it is none of those }
function ParseSize(s: string; out v: QWord): Boolean;
var mult: QWord; n: QWord; c: Char;
begin
  Result := False;
  if s = '' then Exit;
  mult := 1;
  c := UpCase(s[Length(s)]);
  case c of
    'K': mult := QWord(1) shl 10;
    'M': mult := QWord(1) shl 20;
    'G': mult := QWord(1) shl 30;
  end;
  if mult > 1 then Delete(s, Length(s), 1);
  if not TryStrToQWord(s, n) then Exit;
  if (n > 0) and (n > High(QWord) div mult) then Exit;
  v := n * mult;
  Result := True;
end;

{ where the command is among the arguments (past a leading --cpu) }
function CommandIndex: Integer;
begin
  Result := 1;
  while (Result < ArgCount) and (Copy(args[Result], 1, 6) = '--cpu=') do Inc(Result);
end;

{ --cpu: the path asked for, or a usage error if this processor (or this
  build) does not have it }
procedure ApplyCpu;
begin
  if not cpuGiven then Exit;
  if not SetCpuPath(cpuWanted) then
    UsageError('--cpu=' + CPU_PATH_NAMES[cpuWanted] + ': this processor or this build does not have it; it has: ' +
               SupportedPaths);
end;

{ "--cpu avx2": the value goes after an equals sign (next: where it is) }
procedure CpuSpaced(next: Integer);
begin
  if next <= ArgCount then UsageError('"--cpu ' + args[next] + '": write --cpu=' + args[next])
  else UsageError('--cpu needs a path: --cpu=plain, --cpu=sse41 or --cpu=avx2');
end;

procedure ParseArgs;
var i: Integer; a, v: string; n: Integer; onlyFiles: Boolean;

  function NextValue: string;
  begin
    if i >= ArgCount then UsageError(a + ' needs a value');
    Inc(i);
    Result := args[i];
  end;

begin
  command := cmNone; inputs := TStringList.Create;
  outArg := ''; outDir := ''; force := False; keepCorrupt := False; dryRun := False; quiet := False;
  fastModel := False; noVerify := False; cleanTemps := False;
  stats := False; jsonOut := False; withFile := False; runs := 3; runsGiven := False; thGiven := False;
  cpuGiven := False;
  threads := DefaultThreads;
  maxOutput := DEFAULT_MAX_OUTPUT;
  ReadArgs;
  if ArgCount = 0 then Usage(2);
  { --cpu may come before the command too }
  i := 1;
  while (i < ArgCount) and (Copy(args[i], 1, 6) = '--cpu=') do begin
    if not ParseCpuPath(Copy(args[i], 7, MaxInt), cpuWanted) then
      UsageError('--cpu: plain, sse41 or avx2, not "' + Copy(args[i], 7, MaxInt) + '"');
    cpuGiven := True;
    Inc(i);
  end;
  a := args[i];
  if a = '--cpu' then CpuSpaced(i + 1);
  if (a = '-h') or (a = '--help') then Usage(0);
  if (a = '--version') or (a = '-V') then begin
    ApplyCpu;
    Writeln('pja ', PJA_VERSION);
    Write(SystemText(False));
    Finish(0);
  end;
  if a = 'a' then command := cmCompress
  else if a = 'x' then command := cmExtract
  else if a = 'list' then command := cmList
  else if a = 't' then command := cmTest
  else if a = 'info' then command := cmInfo
  else if a = 'report' then command := cmReport
  else if a = 'bench' then command := cmBench
  else if a = 'selftest' then command := cmSelftest
  else UsageError('unknown command "' + a + '": a, x, list, t, info, report, bench or selftest');
  onlyFiles := False;
  i := i + 1;
  while i <= ArgCount do begin
    a := args[i];
    if onlyFiles or (a = '') or (a[1] <> '-') or (a = '-') then inputs.Add(a)
    else if a = '--' then onlyFiles := True
    else if a = '--cpu' then CpuSpaced(i + 1)
    else if (a = '-h') or (a = '--help') then Usage(0)
    else if a = '-o' then outArg := NextValue
    else if Copy(a, 1, 13) = '--output-dir=' then outDir := Copy(a, 14, MaxInt)
    else if (a = '-f') or (a = '--force') then force := True
    else if (a = '-n') or (a = '--dry-run') then dryRun := True
    else if (a = '-q') or (a = '--quiet') then quiet := True
    else if a = '--keep-corrupt' then keepCorrupt := True
    else if a = '--fast' then fastModel := True
    else if a = '--no-verify' then noVerify := True
    else if a = '--clean-temps' then cleanTemps := True
    else if a = '--no-sync' then SyncToDisk := False
    else if a = '--stats' then stats := True
    else if a = '--json' then jsonOut := True
    else if a = '--with-file' then withFile := True
    else if Copy(a, 1, 6) = '--cpu=' then begin
      if not ParseCpuPath(Copy(a, 7, MaxInt), cpuWanted) then
        UsageError('--cpu: plain, sse41 or avx2, not "' + Copy(a, 7, MaxInt) + '"');
      cpuGiven := True;
    end else if a = '-r' then begin
      v := NextValue;
      if not TryStrToInt(v, n) or (n < 1) or (n > 1000) then UsageError('-r: a number from 1 to 1000, not "' + v + '"');
      runs := n;
      runsGiven := True;
    end else if (a = '-th') or (Copy(a, 1, 10) = '--threads=') then begin
      if a = '-th' then v := NextValue else v := Copy(a, 11, MaxInt);
      if not TryStrToInt(v, n) or (n < 1) or (n > 64) then UsageError('threads: a number from 1 to 64, not "' + v + '"');
      threads := n;
      thGiven := True;
    end else if Copy(a, 1, 13) = '--max-output=' then begin
      if not ParseSize(Copy(a, 14, MaxInt), maxOutput) then
        UsageError('--max-output: a size like 256M, 1G or 0, not "' + Copy(a, 14, MaxInt) + '"');
      if maxOutput = 0 then maxOutput := High(QWord);
    end
    { glued values were the old packJPG spelling: say what to write instead }
    else if Copy(a, 1, 3) = '-th' then UsageError('"' + a + '": write -th ' + Copy(a, 4, MaxInt))
    else UsageError('unknown option "' + a + '"');
    Inc(i);
  end;
  {$ifdef MSWINDOWS} ExpandWildcards; {$endif}
  if (inputs.Count = 0) and not (command in [cmReport, cmSelftest]) then UsageError('no input files');
  if (outArg <> '') and (outDir <> '') then UsageError('-o and --output-dir together');
  if (command in [cmList, cmTest, cmInfo, cmBench, cmSelftest]) and ((outArg <> '') or (outDir <> '')) then
    UsageError(args[CommandIndex] + ' writes nothing');
  if fastModel and (command <> cmCompress) then UsageError('--fast is for a');
  if noVerify and (command <> cmCompress) then UsageError('--no-verify is for a');
  if stats and not (command in [cmCompress, cmExtract, cmTest]) then UsageError('--stats is for a, x and t');
  if jsonOut and not (command in [cmCompress, cmExtract, cmTest, cmInfo, cmList]) then
    UsageError('--json is for a, x, t, info and list');
  if withFile and (command <> cmReport) then UsageError('--with-file is for report');
  if withFile and (inputs.Count = 0) then UsageError('--with-file copies the FILE of the report: give one');
  if runsGiven and (command <> cmBench) then UsageError('-r is for bench');
  if (command in [cmTest, cmInfo, cmReport, cmBench, cmSelftest]) and (force or dryRun or keepCorrupt) then
    UsageError('-f, -n and --keep-corrupt are for a and x');
  { durable writes: list, t, info and selftest write nothing; bench and
    report write, but only their own files (bench in a directory of its own) }
  if (cleanTemps or not SyncToDisk) and (command in [cmList, cmTest, cmInfo, cmSelftest]) then
    UsageError(args[CommandIndex] + ' writes nothing');
  if cleanTemps and not (command in [cmCompress, cmExtract]) then UsageError('--clean-temps is for a and x');
  if (command = cmReport) and (outDir <> '') then UsageError('report: -o names the report');
  if (command = cmReport) and (inputs.Count > 1) then UsageError('report takes one file');
  if (command = cmSelftest) and (inputs.Count > 0) then UsageError('selftest takes no files: its samples are inside');
  if (command = cmSelftest) and thGiven then UsageError('selftest picks its own threads (1 and 2)');
end;

function ReadWhole(const f: string; out data: TBytes): Boolean;
var s: TFileStream;
begin
  data := nil;
  Result := False;
  if DirectoryExists(f) then begin Fail(f + ': is a directory'); Exit; end;
  {$ifdef MSWINDOWS}
  { a pattern still here matched nothing (no Windows name has * or ?) }
  if LastDelimiter('*?', f) > 0 then begin Fail(f + ': no file matches'); Exit; end;
  {$endif}
  StageEnter(stRead);
  try
    s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone);
    try
      if QWord(s.Size) > MAX_INPUT then begin Fail(f + ': larger than 2 GiB'); Exit; end;
      SetLength(data, s.Size);
      if s.Size > 0 then s.ReadBuffer(data[0], s.Size);
    finally
      s.Free;
    end;
    Result := True;
    CurJob^.inBytes := Length(data);
  except
    on e: Exception do Fail(f + ': ' + e.Message);
  end;
  StageEnter(stNone);
end;

function EndsWithSeparator(const s: string): Boolean;
begin
  Result := (s <> '') and ((s[Length(s)] = '/') or (s[Length(s)] = DirectorySeparator));
end;

{ Where the output of `input` goes, named `name` by default. }
function OutputPath(const input, name: string): string;
var dir: string;
begin
  dir := outDir;
  if outArg <> '' then begin
    if DirectoryExists(outArg) or EndsWithSeparator(outArg) then dir := outArg
    else Exit(outArg);
  end;
  if dir = '' then Result := ExtractFilePath(input) + name
  else Result := IncludeTrailingPathDelimiter(dir) + name;
end;

function IsPja(const d: TBytes): Boolean;
var i: Integer;
begin
  Result := Length(d) >= 4;
  if Result then
    for i := 0 to 3 do if d[i] <> MAGIC[i] then Exit(False);
end;

function Human(n: QWord): string;
begin
  if n >= 10 * 1024 * 1024 then Result := Format('%.1f MB', [n / (1024 * 1024)])
  else if n >= 10 * 1024 then Result := Format('%.1f KB', [n / 1024])
  else Result := IntToStr(n) + ' B';
end;

var
  { every output this run has taken, and every input, by PathKey; Objects
    is the job's index }
  outKeys, inKeys: TStringList;
  claimLock: TRTLCriticalSection;

{ The same file for the same text: absolute, without . and .., and on
  Windows without case. Links are not resolved. }
function PathKey(const p: string): string;
begin
  Result := ExpandFileName(p);
  {$ifdef MSWINDOWS} Result := UTF8Encode(WideLowerCase(UTF8Decode(Result))); {$endif}
end;

function NewKeyList: TStringList;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := True;
  Result.UseLocale := False;
  Result.Duplicates := dupAccept;
  Result.Sorted := True;
end;

{ Takes path as the output of the current job. Without this, with -f two
  inputs with the same output (a.jpg and a.jpeg, or the same name from two
  folders with --output-dir) both said they were written, and only the last
  one was there; one could also replace another job's input before it was
  read. False, and the job failed, if the path is another job's. }
function Claim(const path: string): Boolean;
var key: string; i, j, k: Integer;
begin
  key := PathKey(path); k := CurJob^.index;
  Result := False;
  EnterCriticalSection(claimLock);
  try
    if outKeys.Find(key, i) then begin
      j := PtrInt(outKeys.Objects[i]);
      if j <> k then begin Fail(path + ': also the output of ' + jobs[j].name + ' in this run'); Exit; end;
      Exit(True);
    end;
    if inKeys.Find(key, i) then begin
      while (i > 0) and (inKeys[i - 1] = key) do Dec(i);
      while (i < inKeys.Count) and (inKeys[i] = key) do begin
        if PtrInt(inKeys.Objects[i]) <> k then begin Fail(path + ': also an input of this run'); Exit; end;
        Inc(i);
      end;
    end;
    outKeys.AddObject(key, TObject(PtrInt(k)));
    Result := True;
  finally
    LeaveCriticalSection(claimLock);
  end;
end;

{ Anything under that name, a link that leads nowhere included (FileExists
  follows links, and a dangling one said no where the write then failed) }
function Exists(const path: string): Boolean;
{$ifdef UNIX} var st: Stat; {$endif}
begin
  {$ifdef UNIX}
  Result := fpLstat(path, st) = 0;
  {$else}
  Result := FileExists(path) or DirectoryExists(path);
  {$endif}
end;

{ Writes data under path, which must verify against `expected`. }
function Save(const path: string; const data: TBytes; const expected: THash16): Boolean;
var r: TFsResult; o: TOutcome; om: TOnMismatch; note: string;
begin
  Result := False;
  if not Claim(path) then Exit;
  { what an interrupted run left in this directory: a notice, not a failure }
  note := CheckLeftovers(path, cleanTemps and not dryRun);
  if note <> '' then CurJob^.errText := CurJob^.errText + 'pja: ' + note + LineEnding;
  { -n checks this too: it said yes to what the real run then refused }
  if not force and Exists(path) then begin
    Fail(path + ': already exists (-f to replace it)');
    Exit;
  end;
  if dryRun then Exit(True);
  if keepCorrupt then om := omKeep else om := omDelete;
  StageEnter(stWrite);
  r := WriteVerified(path, data, expected, om, force, o);
  StageEnter(stNone);
  { in place and whole, but its name may not survive a power cut }
  if r.error = feNotSynced then begin
    Fail(o.path + ': written, but its directory could not be flushed to the disk: ' +
         SysErrorMessage(r.code) + ' (' + r.Text + ')');
    if o.kind = ocKept then Fail(path + ': does not verify; kept as ' + o.path);
    Exit;
  end;
  if not r.Ok then begin
    { the system's own words for its error, and its number }
    if r.code >= 0 then Fail(path + ': could not write it: ' + SysErrorMessage(r.code) + ' (' + r.Text + ')')
    else Fail(path + ': could not write it (' + r.Text + ')');
    Exit;
  end;
  case o.kind of
    ocVerified: Result := True;
    ocDeleted: Fail(path + ': does not verify; nothing written');
    ocKept: Fail(path + ': does not verify; kept as ' + o.path);
  end;
end;

function StoredNote(const pja: TBytes): string;
begin
  if (Length(pja) > 5) and ((pja[5] and FLAG_STORED) <> 0) then Result := '  (stored as is)' else Result := '';
end;

{ PJA did not take it as a JPEG, and it went as bytes, or it repaired an
  encoder's slip first: why }
function BytesNote(const r: TPackResult): string;
begin
  if r.codec.asBytes then Result := '  (as bytes: ' + r.codec.jpeg.Text + ')'
  else if r.codec.repaired then Result := '  (repaired: ' + r.codec.jpeg.Text + ')'
  { JPEG 2000: its codestreams modelled (stream version 8's mode 1), or
    none of them }
  else if r.codec.j2k and (r.codec.j2kModelled > 0) then Result := '  (JPEG 2000)'
  else if r.codec.j2k then Result := '  (JPEG 2000: as bytes)'
  else Result := '';
end;

{ --stats: where the file's time went (pjastage), and the threads and
  bands; pja is the .pja written or read }
procedure StatsOf(const pja: TBytes);
var t: TStageTimes; st: TStage; o: TInfoNode; p: TPja; bands: Integer; line: string; total: Double;
begin
  if not stats then Exit;
  t := StageTimes;
  bands := 0;
  if Open(pja, p).Ok and not p.stored then begin
    if p.orig_size <= maxOutput then bands := StreamBands(p.payload, p.orig_size);
  end;
  o := JobNode.Obj('stats');
  line := '';
  total := 0;
  for st := Low(TStage) to High(TStage) do
    if t[st] > 0 then begin
      total := total + t[st];
      o.Fixed(STAGE_NAMES[st] + '_ms', t[st] * 1000, 3);
      if line <> '' then line := line + ', ';
      line := line + STAGE_NAMES[st] + ' ' + DotNumber(t[st] * 1000, 2) + ' ms';
    end;
  o.Fixed('total_ms', total * 1000, 3);
  o.Num('threads', bandThreads);
  o.Num('bands', bands);
  { with -q the file's own line is not there: the stats name it }
  if not jsonOut and quiet then CurJob^.outText := CurJob^.outText + CurJob^.name + ':' + LineEnding;
  if not jsonOut then
    CurJob^.outText := CurJob^.outText + '  stats: ' + line + '; total ' + DotNumber(total * 1000, 2) + ' ms; ' +
                       IntToStr(bandThreads) + ' thread(s), ' + IntToStr(bands) + ' band(s)' + LineEnding;
end;

procedure CompressOne(const f: string);
var d, pja: TBytes; r: TPackResult; path: string;
begin
  if not ReadWhole(f, d) then Exit;
  if IsPja(d) then begin Fail(f + ': already a .pja'); Exit; end;
  { the extension, as it is written, for x to give it back }
  r := Pack(d, pja, bandThreads, False, not noVerify, Copy(ExtractFileExt(f), 2, MaxInt), True);
  if not r.Ok then begin Fail(f + ': ' + r.Text); Exit; end;
  path := OutputPath(f, ChangeFileExt(ExtractFileName(f), '.pja'));
  if Save(path, pja, Blake3_128(pja)) then begin
    CurJob^.outBytes := Length(pja);
    JobNode.Str('output', path);
    JobNode.Num('original_size', Length(d));
    JobNode.Num('pja_size', Length(pja));
    if Length(d) > 0 then JobNode.Fixed('ratio_percent', 100 * Length(pja) / Length(d));
    JobNode.Bool('stored', StoredNote(pja) <> '');
    if r.codec.asBytes then JobNode.Str('as_bytes', r.codec.jpeg.Text);
    if r.codec.repaired then JobNode.Str('repaired', r.codec.jpeg.Text);
    if not quiet then
      Say(f + ' -> ' + path + '  ' + Human(Length(d)) + ' -> ' + Human(Length(pja)) +
          Format('  %.2f%%', [100 * Length(pja) / Length(d)]) +
          { the codec would not have made it smaller }
          StoredNote(pja) + BytesNote(r));
  end;
  StatsOf(pja);
end;

procedure ExtractOne(const f: string);
var d, orig: TBytes; r: TPackResult; path, ext: string; h: THash16;
begin
  if not ReadWhole(f, d) then Exit;
  r := Unpack(d, maxOutput, orig, h, bandThreads);
  if r.err = ukTooLarge then begin
    Fail(f + ': the original is larger than --max-output'); Exit;
  end;
  if not (r.Ok or (r.err = ukHashMismatch)) then begin Fail(f + ': ' + r.Text); Exit; end;
  { -n does everything but write: a hash that does not match fails it as
    it fails x (Save, which -n stops before, is where x finds it) }
  if dryRun and (r.err = ukHashMismatch) then begin Fail(f + ': does not verify (' + r.Text + ')'); Exit; end;
  { the original's own extension; a .pja without one (version 3) by the content }
  if r.ext <> '' then ext := '.' + r.ext
  else if IsJls(orig) then ext := '.jls'
  else if IsMpo(orig) then ext := '.mpo'
  else if J2kExtension(orig) <> '' then ext := '.' + J2kExtension(orig)
  else ext := '.jpg';
  path := OutputPath(f, ChangeFileExt(ExtractFileName(f), ext));
  { a hash that does not match goes through Save as well: it deletes it, or
    keeps it under another name with --keep-corrupt }
  if Save(path, orig, h) then begin
    CurJob^.outBytes := Length(orig);
    JobNode.Str('output', path);
    JobNode.Num('original_size', Length(orig));
    JobNode.Num('pja_size', Length(d));
    if not quiet then Say(f + ' -> ' + path + '  ' + Human(Length(orig)));
  end;
  StatsOf(d);
end;

{ t: what x does, without writing: the size and the hash checked }
procedure TestOne(const f: string);
var d, orig: TBytes; r: TPackResult; h: THash16;
begin
  if not ReadWhole(f, d) then Exit;
  if not IsPja(d) then begin Fail(f + ': FAILED: not a .pja'); Exit; end;
  r := Unpack(d, maxOutput, orig, h, bandThreads);
  StageEnter(stNone);
  if r.err = ukTooLarge then begin Fail(f + ': FAILED: the original is larger than --max-output'); Exit; end;
  if not r.Ok then begin Fail(f + ': FAILED: ' + r.Text); Exit; end;
  CurJob^.outBytes := Length(orig);
  JobNode.Num('original_size', Length(orig));
  JobNode.Num('pja_size', Length(d));
  if not quiet then Say(f + ': OK  ' + Human(Length(orig)) + ', size and BLAKE3-128 verified');
  StatsOf(d);
end;

{ info: the structure, and what PJA does with it }
procedure InfoOne(const f: string);
var d: TBytes; n, bug: TInfoNode; sl: TStringList;
begin
  if not ReadWhole(f, d) then Exit;
  n := DescribeFile(f, d, False, bandThreads, maxOutput);
  bug := n.Find('internal_error');
  if bug <> nil then begin
    CurJob^.bug := True;
    Fail(f + ': internal error: ' + bug.value);
  end;
  if jsonOut then begin
    CurJob^.node.Free;
    CurJob^.node := n;
    Exit;
  end;
  sl := TStringList.Create;
  try
    n.Render(sl, 2);
    sl.Delete(0);
    sl.Insert(0, f);
    Say(TrimRight(sl.Text));
  finally
    sl.Free;
    n.Free;
  end;
end;

function ExtNote(const ext: string): string;
begin
  if ext = '' then Result := '' else Result := ', as .' + ext;
end;

{ a file of the JPEG 2000 family (codec stream version 8) }
function KindNote(const p: TPja): string;
begin
  if not p.stored and (Length(p.payload) > 0) and (p.payload[0] = STREAM_J2K) then Result := ', JPEG 2000'
  else Result := '';
end;

procedure ListOne(const f: string);
var d: TBytes; p: TPja; r: TPjaResult; i: Integer; hex: string;
begin
  if not ReadWhole(f, d) then Exit;
  r := Open(d, p);
  if not r.Ok then begin Fail(f + ': ' + r.Text); Exit; end;
  hex := '';
  for i := 0 to 15 do hex := hex + LowerCase(IntToHex(p.hash[i], 2));
  JobNode.Num('original_size', p.orig_size);
  JobNode.Num('pja_size', Length(d));
  JobNode.Fixed('ratio_percent', 100 * Length(d) / p.orig_size);
  JobNode.Bool('stored', p.stored);
  JobNode.Str('extension', p.ext);
  JobNode.Str('blake3_128', hex);
  Say(f + '  original ' + IntToStr(p.orig_size) + ' B, .pja ' + IntToStr(Length(d)) + ' B' +
      Format(' (%.2f%%)', [100 * Length(d) / p.orig_size]) + StoredNote(d) + ExtNote(p.ext) + KindNote(p) + '  blake3-128 ' + hex);
end;

var
  nextJob, nextPrint: LongInt;
  { the jobs in the order the workers take them }
  order: array of Integer;
  printLock: TRTLCriticalSection;
  { the bytes every file read and wrote, for the summary }
  sumIn, sumOut: Int64;
  { what writing the output met, '' if nothing }
  outputError: string;

{ PJA_TEST_CRASH=range or access: a bug on purpose (cli.sh checks how the
  command ends then) }
var crashTarget: PInteger = nil;

procedure CrashTest;
var w: string;
begin
  w := GetEnvironmentVariable('PJA_TEST_CRASH');
  if w = 'range' then raise ERangeError.Create('Range check error (PJA_TEST_CRASH)');
  if w = 'access' then crashTarget^ := 1;
end;

procedure RunJob(k: Integer);
begin
  CurJob := @jobs[k];
  jobs[k].node := TInfoNode.Create(ikObject);
  jobs[k].node.Str('file', jobs[k].name);
  StageReset;
  try
    { failed before starting: its output is another input's }
    if not jobs[k].failed then begin
      CrashTest;
      case command of
        cmCompress: CompressOne(jobs[k].name);
        cmExtract: ExtractOne(jobs[k].name);
        cmList: ListOne(jobs[k].name);
        cmTest: TestOne(jobs[k].name);
        cmInfo: InfoOne(jobs[k].name);
      end;
    end;
  except
    on e: Exception do begin
      if not NotABug(e) then begin
        jobs[k].bug := True;
        Fail(jobs[k].name + ': internal error: ' + e.ClassName + ': ' + e.Message);
      end else Fail(jobs[k].name + ': ' + e.ClassName + ': ' + e.Message);
    end;
  end;
  if jsonOut then begin
    { info's "ok": the file was read and described (what PJA does with
      it is under "pja") }
    jobs[k].node.Bool('ok', not jobs[k].failed);
    if jobs[k].errors <> '' then jobs[k].node.Str('error', jobs[k].errors);
    if jobs[k].bug and (jobs[k].node.Find('internal_error') = nil) then jobs[k].node.Bool('internal_error', True);
    jobs[k].outText := jobs[k].node.Json + LineEnding;
  end;
  FreeAndNil(jobs[k].node);
  { print every finished job that is next in line }
  EnterCriticalSection(printLock);
  try
    jobs[k].done := True;
    while (nextPrint < Length(jobs)) and jobs[nextPrint].done do begin
      { Output and StdErr are per thread in FPC, each with its own buffer:
        flushed here, inside the lock, or a worker's lines would come out
        when it ends }
      { the output that cannot be written (a full disk) is said once, at
        the end, and the rest of the run goes on without it }
      if (jobs[nextPrint].outText <> '') and (outputError = '') then
        try
          Write(jobs[nextPrint].outText); Flush(Output);
        except
          on e: Exception do begin
            TextRec(Output).BufPos := 0;
            InOutRes := 0;
            outputError := e.Message;
          end;
        end;
      if jobs[nextPrint].errText <> '' then begin Write(StdErr, jobs[nextPrint].errText); Flush(StdErr); end;
      if jobs[nextPrint].failed then Inc(errors);
      if jobs[nextPrint].bug then begin
        if bugs = 0 then bugFile := jobs[nextPrint].name;
        Inc(bugs);
      end;
      Inc(sumIn, jobs[nextPrint].inBytes);
      Inc(sumOut, jobs[nextPrint].outBytes);
      jobs[nextPrint].outText := ''; jobs[nextPrint].errText := '';
      Inc(nextPrint);
    end;
  finally
    LeaveCriticalSection(printLock);
  end;
end;

{ takes the next input until none is left }
procedure Work;
var k: LongInt;
begin
  repeat
    k := InterlockedIncrement(nextJob) - 1;
    if k >= Length(jobs) then Break;
    RunJob(order[k]);
  until False;
end;

{ With several workers the largest files go first (by the size of the
  input: the .jpg for a, the .pja for x and l), so that no big file is left
  for the end while the other threads wait: on 30 photos of sizes 10x apart,
  in name order, -th 8 took up to a fifth longer. A file that cannot be
  read counts as 0 and goes last. The lines still come out in the order of
  the inputs (nextPrint), and with one worker nothing changes, so x's
  outputs are taken in the input order there, as before. }
procedure ScheduleJobs(workers: Integer);
var i, j, t: Integer; size: array of Int64; sr: TSearchRec;
begin
  order := nil; size := nil;
  SetLength(order, Length(jobs)); SetLength(size, Length(jobs));
  for i := 0 to High(jobs) do begin
    order[i] := i; size[i] := 0;
    if (workers > 1) and (FindFirst(jobs[i].name, faAnyFile, sr) = 0) then begin
      size[i] := sr.Size; FindClose(sr);
    end;
  end;
  { stable insertion sort, largest first: the same order every run }
  for i := 1 to High(order) do begin
    t := order[i]; j := i - 1;
    while (j >= 0) and (size[order[j]] < size[t]) do begin order[j + 1] := order[j]; Dec(j); end;
    order[j + 1] := t;
  end;
end;

type
  TWorker = class(TJoinThread)
    procedure Execute; override;
  end;

procedure TWorker.Execute;
begin
  Work;
  ReleaseThreadModels;
end;

{ the end of a run that met a bug: what to do about it }
procedure BugNote(const f: string);
var name: string;
begin
  name := f;
  if name = '' then name := 'FILE';
  if Pos(' ', name) > 0 then name := '"' + name + '"';
  Writeln(StdErr, 'pja: This is a bug in PJA. Please run: pja report ', name, ' and open an issue at ', ISSUES_URL);
end;

{ pja report }
function DoReport: Integer;
var d: TBytes; f, title, text, url, copied, msg, dir: string; job: TFileJob; rest: array of string; i: Integer;
    r: TFsResult; o: TOutcome; tb: TBytes; cut: Boolean;
begin
  Result := 0;
  f := '';
  d := nil;
  job := Default(TFileJob);
  CurJob := @job;
  if inputs.Count > 0 then begin
    f := inputs[0];
    if not ReadWhole(f, d) then begin Write(StdErr, job.errText); Exit(1); end;
  end;
  rest := nil;
  SetLength(rest, ArgCount);
  for i := 1 to ArgCount do rest[i - 1] := args[i];
  text := BuildReport(f, d, rest, threads, maxOutput, title);
  url := IssueUrl(title, text, cut);
  if outArg = '' then Write(text)
  else begin
    tb := nil;
    SetLength(tb, Length(text));
    if Length(text) > 0 then Move(text[1], tb[0], Length(text));
    r := WriteVerified(outArg, tb, Blake3_128(tb), omDelete, force, o);
    { whole and in place, but its name may not survive a power cut }
    if r.error = feNotSynced then begin
      Writeln(StdErr, 'pja: ', outArg, ': written, but its directory could not be flushed to the disk: ',
              SysErrorMessage(r.code), ' (', r.Text, ')');
      Exit(1);
    end;
    if not r.Ok then begin
      if r.code >= 0 then Writeln(StdErr, 'pja: ', outArg, ': could not write it: ', SysErrorMessage(r.code), ' (', r.Text, ')')
      else Writeln(StdErr, 'pja: ', outArg, ': could not write it (', r.Text, ')');
      Exit(1);
    end;
    Writeln('pja: the report is in ', outArg);
  end;
  if withFile and (f <> '') then begin
    if outArg <> '' then dir := ExtractFilePath(outArg) else dir := '';
    copied := CopyBeside(f, d, dir, msg);
    if copied = '' then begin Writeln(StdErr, 'pja: ', msg); Result := 1; end
    else Writeln('pja: the file, to attach if you wish: ', copied,
                 ' (GitHub takes .jpg; zip a .jls, .mpo or .pja first)');
  end;
  Writeln;
  if cut then
    Writeln('Open an issue with this report (the link has room for part of it: paste the whole report ',
            'in the issue, check it and add the steps):')
  else Writeln('Open an issue with this report (the link holds it; check it and add the steps):');
  Writeln(url);
end;

{ the summary of --stats and --json }
procedure Summary(wall: Double);
var o, s: TInfoNode; orig: Int64;
begin
  if jsonOut then begin
    o := TInfoNode.Create(ikObject);
    try
      s := o.Obj('summary');
      s.Str('command', args[CommandIndex]);
      s.Num('files', Length(jobs));
      s.Num('failed', errors);
      s.Num('bugs', bugs);
      s.Num('bytes_in', sumIn);
      s.Num('bytes_out', sumOut);
      s.Fixed('seconds', wall, 6);
      s.Num('threads', threads);
      Writeln(o.Json);
    finally
      o.Free;
    end;
  end else if stats then begin
    { MB/s of the originals: what a reads, what x and t give }
    if command = cmCompress then orig := sumIn else orig := sumOut;
    Write('pja: ', Length(jobs), ' file(s), ', Human(sumIn), ' -> ', Human(sumOut), ', ',
          DotNumber(wall * 1000, 2), ' ms, ', threads, ' thread(s)');
    if wall > 0 then Write(', ', DotNumber(orig / (1024 * 1024) / wall, 2), ' MB/s');
    Writeln;
  end;
end;

var i, n, workers: Integer; pool: array of TWorker; path: string; started: Double;
begin
  { On Unix only '/' separates: the RTL's ExtractFileName and ChangeFileExt
    also cut at '\', a plain character there, so 'a\x.jpg' and 'b\x.jpg'
    both went to x.pja. (The extension kept is the same: one with '\' is
    not one the format takes.) }
  {$ifndef MSWINDOWS} AllowDirectorySeparators := ['/']; {$endif}
  { the commit, from PJA_COMMIT at build time (as the plugin's; '' if not
    set): here, in the program, which is compiled every time }
  BuildCommit := {$I %PJA_COMMIT%};
  BuildDate := {$I %DATE%};
  errors := 0; bugs := 0; bugFile := ''; sumIn := 0; sumOut := 0; outputError := '';
  try
  ParseArgs;
  { before any write: report's and bench's too }
  InstallInterruptCleanup;
  ApplyCpu;
  StagesOn := stats;
  case command of
    cmReport: Finish(DoReport);
    cmBench: Finish(RunBench(inputs, runs, threads));
    { --cpu: that path alone }
    cmSelftest: Finish(RunSelftest(quiet, cpuGiven, cpuWanted));
  end;
  started := Seconds;
  if (outArg <> '') and (inputs.Count > 1) and not (DirectoryExists(outArg) or EndsWithSeparator(outArg)) then
    UsageError('-o with several inputs has to be a directory');
  jobs := nil;
  SetLength(jobs, inputs.Count);
  InitCriticalSection(claimLock);
  outKeys := NewKeyList; inKeys := NewKeyList;
  for i := 0 to inputs.Count - 1 do begin
    jobs[i] := Default(TFileJob);
    jobs[i].name := inputs[i];
    jobs[i].index := i;
    inKeys.AddObject(PathKey(inputs[i]), TObject(PtrInt(i)));
  end;
  { a's outputs follow from the names alone: taken here, in the order of the
    inputs, so it is always the later one that fails. x's come from inside
    the .pja, and are taken when written. An input that is not there takes
    nothing: it fails on its own, and must not take a later one down. }
  if command = cmCompress then
    for i := 0 to High(jobs) do if FileExists(jobs[i].name) then begin
      CurJob := @jobs[i];
      path := OutputPath(jobs[i].name, ChangeFileExt(ExtractFileName(jobs[i].name), '.pja'));
      Claim(path);
    end;
  { the threads go to files first (a photo is usually one band), and what
    is left to each file's bands }
  workers := threads;
  if workers > inputs.Count then workers := inputs.Count;
  bandThreads := threads div workers;
  nextJob := 0; nextPrint := 0;
  ScheduleJobs(workers);
  InitCriticalSection(printLock);
  pool := nil;
  SetLength(pool, workers - 1);
  { a thread the system refuses (a host at its limit) leaves the files to
    the ones it gave and to this one: the same outputs, only slower }
  n := 0;
  while n < Length(pool) do begin
    try
      pool[n] := TWorker.Create(False);
    except
      on EThread do Break;
    end;
    Inc(n);
  end;
  SetLength(pool, n);
  Work;
  for i := 0 to High(pool) do begin pool[i].Join; pool[i].Free; end;
  DoneCriticalSection(printLock);
  DoneCriticalSection(claimLock);
  if (stats or jsonOut) and (outputError = '') then Summary(Seconds - started);
  if outputError <> '' then begin
    Writeln(StdErr, 'pja: could not write the output: ', outputError);
    if bugs > 0 then begin BugNote(bugFile); Halt(3); end;
    Halt(1);
  end;
  if errors > 0 then begin
    if inputs.Count > 1 then Writeln(StdErr, 'pja: ', errors, ' of ', inputs.Count, ' files failed');
    if bugs > 0 then begin BugNote(bugFile); Halt(3); end;
    Halt(1);
  end;
  Finish(0);
  except
    { anything not caught where a file is worked on: a bug }
    on e: Exception do begin
      { a write or a read the system refused (a full disk): not a bug }
      if NotABug(e) then begin
        if e is EInOutError then OutputFailed(e.Message) else Writeln(StdErr, 'pja: ', e.Message);
        Halt(1);
      end;
      Writeln(StdErr, 'pja: internal error: ', e.ClassName, ': ', e.Message);
      if inputs <> nil then begin
        if inputs.Count > 0 then BugNote(inputs[0]) else BugNote('');
      end else BugNote('');
      Halt(3);
    end;
  end;
end.
