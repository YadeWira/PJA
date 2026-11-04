{ Threads the system will not give (a host at its thread limit): the bands
  no thread was had for run on the caller's thread, the threads already
  running are waited for, and the stream and the JPEG back are those of one
  thread. BeginThread is wrapped to give `allowed` threads and then none.

    test_threads <JPEG with several bands>... }
program test_threads;
{$I ../pja.inc}
uses {$ifdef unix} cthreads, {$endif} SysUtils, Classes, pjacodec;

var
  realBegin: TBeginThreadHandler;
  allowed, refused: LongInt;

function ScarceBeginThread(sa: Pointer; stackSize: PtrUInt; fn: TThreadFunc; p: Pointer;
                           flags: DWord; var id: TThreadID): TThreadID;
begin
  if InterLockedDecrement(allowed) < 0 then begin
    InterLockedIncrement(refused);
    id := TThreadID(0);
    Exit(TThreadID(0));
  end;
  Result := realBegin(sa, stackSize, fn, p, flags, id);
end;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

function Same(const a, b: TBytes): Boolean;
begin Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a))); end;

const GIVEN: array[0..1] of LongInt = (0, 1);
var
  tm: TThreadManager; name: string;
  i, g, cells, failures: Integer; d, st1, st, back: TBytes; r: TCodecResult;

  procedure Check(ok: Boolean; const what: string);
  begin
    Inc(cells);
    if not ok then begin Inc(failures); Writeln('  FAIL ', what, '  ', name); end;
  end;

begin
  GetThreadManager(tm);
  realBegin := tm.BeginThread;
  tm.BeginThread := @ScarceBeginThread;
  allowed := High(LongInt); refused := 0;
  SetThreadManager(tm);
  cells := 0; failures := 0;
  for i := 1 to ParamCount do begin
    d := ReadFile(ParamStr(i)); name := ExtractFileName(ParamStr(i));
    try
      allowed := High(LongInt);
      r := Compress(d, st1, True, 1);
      Check(r.Ok, 'one thread: ' + r.Text);
      if not r.Ok then Continue;
      for g := 0 to High(GIVEN) do begin
        { verified: the encoders and their readers (CompressLive) }
        allowed := GIVEN[g];
        r := Compress(d, st, True, 8);
        Check(r.Ok and Same(st, st1), Format('%d threads given, verified: %s', [GIVEN[g], r.Text]));
        { not verified: the encoders alone (RunBands) }
        allowed := GIVEN[g];
        r := Compress(d, st, False, 8);
        Check(r.Ok and Same(st, st1), Format('%d threads given, not verified: %s', [GIVEN[g], r.Text]));
        allowed := GIVEN[g];
        r := Decompress(st1, back, Length(d), 8);
        Check(r.Ok and Same(back, d), Format('%d threads given, decompressed: %s', [GIVEN[g], r.Text]));
      end;
    except
      on e: Exception do Check(False, e.ClassName + ': ' + e.Message);
    end;
  end;
  allowed := High(LongInt);
  Writeln(Format('%d files, %d cells, %d threads refused, %d failures', [ParamCount, cells, refused, failures]));
  { each file of two bands or more: one thread refused in each call }
  if (failures > 0) or (ParamCount < 1) or (refused < 6 * ParamCount) then Halt(1);
end.
