{ pja selftest (doc/CLI.md): the samples inside the binary (pjaselftest.inc,
  written by tools/gen_selftest.py: a baseline JPEG, a progressive one, an
  arithmetic-coded one, a JPEG-LS) compressed and extracted on every SIMD
  path this machine and this build have (pjasysinfo), with one thread and
  with two (two decode the bands while they are encoded). Each .pja has to
  be the very bytes the include holds, on every path, and each has to come
  back as its sample. }
unit pjaselftest;

{$I pja.inc}
{$ifopt R-}{$fatal pjaselftest: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjaselftest: overflow checks ($Q+) are mandatory}{$endif}

interface

{ Prints a line per path and a summary (only failures and the summary with
  quiet). 0 when every check passed, 1 if not. }
function RunSelftest(quiet: Boolean): Integer;

implementation

uses SysUtils, pjablake3, pjapack, pjasysinfo, pjainfo;

{$I pjaselftest.inc}

function SameBytes(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

function RunSelftest(quiet: Boolean): Integer;
const THREAD_COUNTS: array[0..1] of Integer = (1, 2);
var was, p: TCpuPath; k, t, checks, failed, pathFailed, paths: Integer; data, want, got, back: TBytes;
    r: TPackResult; h: THash16; why, names: string;
begin
  was := CurrentCpuPath;
  checks := 0; failed := 0; paths := 0; names := '';
  if not quiet then begin
    Writeln('pja selftest: ', SELFTEST_COUNT, ' samples inside the binary, on every SIMD path here (',
            SupportedPaths, '), with 1 and 2 threads');
    for k := 0 to SELFTEST_COUNT - 1 do begin
      SelftestSample(k, data, want);
      Writeln('  ', SELFTEST_NAMES[k], ': ', Length(data), ' B -> ', Length(want), ' B, .pja blake3-128 ',
              HexBytes(Blake3_128(want)));
    end;
  end;
  try
    for p := Low(TCpuPath) to High(TCpuPath) do begin
      if not CpuPathSupported(p) then Continue;
      Inc(paths);
      if names <> '' then names := names + ' ';
      names := names + CPU_PATH_NAMES[p];
      SetCpuPath(p);
      pathFailed := 0;
      for k := 0 to SELFTEST_COUNT - 1 do begin
        SelftestSample(k, data, want);
        for t := 0 to High(THREAD_COUNTS) do begin
          Inc(checks);
          why := '';
          r := Pack(data, got, THREAD_COUNTS[t], False, True, SELFTEST_EXTS[k], True);
          if not r.Ok then why := 'compress failed: ' + r.Text
          else if not SameBytes(got, want) then
            why := 'a different .pja: ' + IntToStr(Length(got)) + ' B, blake3-128 ' + HexBytes(Blake3_128(got))
          else begin
            r := Unpack(got, QWord(Length(data)), back, h, THREAD_COUNTS[t]);
            if not r.Ok then why := 'extract failed: ' + r.Text
            else if not SameBytes(back, data) then why := 'extracted to other bytes';
          end;
          if why <> '' then begin
            Inc(failed); Inc(pathFailed);
            Writeln(StdErr, 'pja: selftest: ', SELFTEST_NAMES[k], ' on ', CPU_PATH_NAMES[p], ' with ',
                    THREAD_COUNTS[t], ' thread(s): ', why);
          end;
        end;
      end;
      if not quiet then begin
        if pathFailed = 0 then Writeln('  path ', CPU_PATH_NAMES[p], ': ok')
        else Writeln('  path ', CPU_PATH_NAMES[p], ': ', pathFailed, ' FAILED');
      end;
    end;
  finally
    SetCpuPath(was);
  end;
  if failed = 0 then begin
    Writeln('selftest: ', checks, ' of ', checks, ' checks passed on ', paths, ' path(s) (', names,
            '): every .pja the expected bytes, every sample back');
    Result := 0;
  end else begin
    Writeln(StdErr, 'pja: selftest: ', failed, ' of ', checks, ' checks FAILED. This is a bug in PJA: please run',
            ' pja report and open an issue at ', ISSUES_URL);
    Result := 1;
  end;
end;

end.
