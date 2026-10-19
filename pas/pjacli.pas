{ The pja command: JPEG and JPEG-LS files to .pja and back. doc/CLI.md has
  the switches and the reasons behind them.

    pja a [options] FILE...     compress: photo.jpg -> photo.pja
    pja x [options] FILE...     extract:  photo.pja -> photo.jpg (or .jls)
    pja list FILE...            what each .pja holds

  Nothing is written under an output's name unless it verified: `a` checks
  that its stream decompresses to the input, `x` that the size and the hash
  match. An existing output is only replaced with -f. }
program pjacli;

{$I pja.inc}
{$ifopt R-}{$fatal pjacli: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjacli: overflow checks ($Q+) are mandatory}{$endif}

uses
  {$ifdef UNIX} cthreads, {$endif}
  SysUtils, Classes, pjablake3, pjaformat, pjacodec, pjajls, pjapack, pjafs;

const
  PJA_VERSION = '0.1';
  DEFAULT_MAX_OUTPUT = 256 * 1024 * 1024;
  { the largest input read whole into memory }
  MAX_INPUT = QWord(1) shl 31;

type
  TCommand = (cmNone, cmCompress, cmExtract, cmList);

var
  command: TCommand;
  inputs: TStringList;
  outArg: string;          { -o: a name, or a directory }
  outDir: string;          { --output-dir }
  force, keepCorrupt, dryRun, quiet: Boolean;
  threads: Integer;
  maxOutput: QWord;
  errors: Integer;

procedure Fail(const msg: string);
begin
  Inc(errors);
  Writeln(StdErr, 'pja: ', msg);
end;

procedure Usage(code: Integer);
begin
  Writeln('pja ', PJA_VERSION, ' - lossless recompression of JPEG and JPEG-LS files');
  Writeln;
  Writeln('usage: pja a [options] FILE...     compress to .pja');
  Writeln('       pja x [options] FILE...     extract from .pja');
  Writeln('       pja list FILE...            show what each .pja holds');
  Writeln;
  Writeln('  -o PATH              output name (one input), or directory (ends in / or exists)');
  Writeln('  --output-dir=DIR     output directory');
  Writeln('  -f, --force          replace an existing output (only with something that verified)');
  Writeln('  -th N, --threads=N   threads per file (default: the processors, up to 8)');
  Writeln('  --max-output=SIZE    x: refuse a declared original above SIZE (256M; 0 = no limit)');
  Writeln('  --keep-corrupt       x: keep output that does not verify as NAME.corrupt');
  Writeln('  -n, --dry-run        do everything but write');
  Writeln('  -q, --quiet          only errors');
  Writeln('  --                   the rest are files');
  Halt(code);
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

procedure ParseArgs;
var i: Integer; a, v: string; n: Integer; onlyFiles: Boolean;

  function NextValue: string;
  begin
    if i >= ParamCount then UsageError(a + ' needs a value');
    Inc(i);
    Result := ParamStr(i);
  end;

begin
  command := cmNone; inputs := TStringList.Create;
  outArg := ''; outDir := ''; force := False; keepCorrupt := False; dryRun := False; quiet := False;
  threads := TThread.ProcessorCount;
  if threads > 8 then threads := 8;
  if threads < 1 then threads := 1;
  maxOutput := DEFAULT_MAX_OUTPUT;
  if ParamCount = 0 then Usage(2);
  a := ParamStr(1);
  if (a = '-h') or (a = '--help') then Usage(0);
  if a = '--version' then begin Writeln('pja ', PJA_VERSION); Halt(0); end;
  if a = 'a' then command := cmCompress
  else if a = 'x' then command := cmExtract
  else if a = 'list' then command := cmList
  else UsageError('unknown command "' + a + '": a, x or list');
  onlyFiles := False;
  i := 2;
  while i <= ParamCount do begin
    a := ParamStr(i);
    if onlyFiles or (a = '') or (a[1] <> '-') or (a = '-') then inputs.Add(a)
    else if a = '--' then onlyFiles := True
    else if (a = '-h') or (a = '--help') then Usage(0)
    else if a = '-o' then outArg := NextValue
    else if Copy(a, 1, 13) = '--output-dir=' then outDir := Copy(a, 14, MaxInt)
    else if (a = '-f') or (a = '--force') then force := True
    else if (a = '-n') or (a = '--dry-run') then dryRun := True
    else if (a = '-q') or (a = '--quiet') then quiet := True
    else if a = '--keep-corrupt' then keepCorrupt := True
    else if (a = '-th') or (Copy(a, 1, 10) = '--threads=') then begin
      if a = '-th' then v := NextValue else v := Copy(a, 11, MaxInt);
      if not TryStrToInt(v, n) or (n < 1) or (n > 64) then UsageError('threads: a number from 1 to 64, not "' + v + '"');
      threads := n;
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
  if inputs.Count = 0 then UsageError('no input files');
  if (outArg <> '') and (outDir <> '') then UsageError('-o and --output-dir together');
  if (command = cmList) and ((outArg <> '') or (outDir <> '')) then UsageError('list writes nothing');
end;

function ReadWhole(const f: string; out data: TBytes): Boolean;
var s: TFileStream;
begin
  data := nil;
  Result := False;
  if DirectoryExists(f) then begin Fail(f + ': is a directory'); Exit; end;
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
  except
    on e: Exception do Fail(f + ': ' + e.Message);
  end;
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

{ Writes data under path, which must verify against `expected`. }
function Save(const path: string; const data: TBytes; const expected: THash16): Boolean;
var r: TFsResult; o: TOutcome; om: TOnMismatch;
begin
  Result := False;
  if dryRun then Exit(True);
  if not force and (FileExists(path) or DirectoryExists(path)) then begin
    Fail(path + ': already exists (-f to replace it)');
    Exit;
  end;
  if keepCorrupt then om := omKeep else om := omDelete;
  r := WriteVerified(path, data, expected, om, force, o);
  if not r.Ok then begin
    Fail(path + ': could not write it (' + r.Text + ')');
    Exit;
  end;
  case o.kind of
    ocVerified: Result := True;
    ocDeleted: Fail(path + ': does not verify; nothing written');
    ocKept: Fail(path + ': does not verify; kept as ' + o.path);
  end;
end;

procedure CompressOne(const f: string);
var d, pja: TBytes; r: TPackResult; path: string;
begin
  if not ReadWhole(f, d) then Exit;
  if IsPja(d) then begin Fail(f + ': already a .pja'); Exit; end;
  r := Pack(d, pja, threads);
  if not r.Ok then begin Fail(f + ': ' + r.Text); Exit; end;
  path := OutputPath(f, ChangeFileExt(ExtractFileName(f), '.pja'));
  if Save(path, pja, Blake3_128(pja)) and not quiet then
    Writeln(f, ' -> ', path, '  ', Human(Length(d)), ' -> ', Human(Length(pja)),
            Format('  %.2f%%', [100 * Length(pja) / Length(d)]));
end;

procedure ExtractOne(const f: string);
var d, orig: TBytes; r: TPackResult; path, ext: string; h: THash16;
begin
  if not ReadWhole(f, d) then Exit;
  r := Unpack(d, maxOutput, orig, h, threads);
  if r.err = ukTooLarge then begin
    Fail(f + ': the original is larger than --max-output'); Exit;
  end;
  if not (r.Ok or (r.err = ukHashMismatch)) then begin Fail(f + ': ' + r.Text); Exit; end;
  if IsJls(orig) then ext := '.jls' else ext := '.jpg';
  path := OutputPath(f, ChangeFileExt(ExtractFileName(f), ext));
  { a hash that does not match goes through Save as well: it deletes it, or
    keeps it under another name with --keep-corrupt }
  if Save(path, orig, h) and not quiet then
    Writeln(f, ' -> ', path, '  ', Human(Length(orig)));
end;

procedure ListOne(const f: string);
var d: TBytes; p: TPja; r: TPjaResult; i: Integer; hex: string;
begin
  if not ReadWhole(f, d) then Exit;
  r := Open(d, p);
  if not r.Ok then begin Fail(f + ': ' + r.Text); Exit; end;
  hex := '';
  for i := 0 to 15 do hex := hex + LowerCase(IntToHex(p.hash[i], 2));
  Writeln(f, '  original ', p.orig_size, ' B, stored ', Length(d), ' B',
          Format(' (%.2f%%)', [100 * Length(d) / p.orig_size]), '  blake3-128 ', hex);
end;

var i: Integer;
begin
  errors := 0;
  ParseArgs;
  if (outArg <> '') and (inputs.Count > 1) and not (DirectoryExists(outArg) or EndsWithSeparator(outArg)) then
    UsageError('-o with several inputs has to be a directory');
  for i := 0 to inputs.Count - 1 do
    case command of
      cmCompress: CompressOne(inputs[i]);
      cmExtract: ExtractOne(inputs[i]);
      cmList: ListOne(inputs[i]);
    end;
  if errors > 0 then begin
    if inputs.Count > 1 then Writeln(StdErr, 'pja: ', errors, ' of ', inputs.Count, ' files failed');
    Halt(1);
  end;
end.
