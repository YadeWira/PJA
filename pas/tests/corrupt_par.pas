{ The damaged-input tests' variants, run on every processor: each input k
  has totals[k] variants, cut into chunks that threads take in turn. fn
  tries variant v of input k and says what came of it; the totals do not
  depend on the threads. PJA_TEST_THREADS=n sets their number (1: the
  order of a single thread, for a failure to reproduce). }
unit corrupt_par;
{$I ../pja.inc}

interface

const
  { what a variant gave: none of them, the input taken (decoded,
    rebuilt), taken and the same as the original, or an exception }
  CV_TAKEN = 1;
  CV_SAME = 2;
  CV_FAILURE = 4;

type
  TVariantFn = function(k: Integer; v: Int64; out what: string): Integer;

  TVariantCounts = record
    variants, taken, same, failures: Int64;
  end;

{ a variant v below 8 * flipBytes flips bit v; above, the input is cut to
  v - 8 * flipBytes bytes: what both tests do with each input }
function VariantCount(len, maxBytes: Int64): Int64;

function RunVariants(const totals: array of Int64; fn: TVariantFn): TVariantCounts;

implementation

uses Classes, SysUtils, pjacpu;

{ small: a few variants (a size flipped to a large one) take seconds each,
  and a chunk of them would leave one thread working alone at the end }
const CHUNK = 16;

type
  TItem = record k: Integer; first, last: Int64; end;

  TWorker = class(TThread)
    counts: TVariantCounts;
    procedure Execute; override;
  end;

var
  items: array of TItem;
  next: LongInt;
  fnRun: TVariantFn;
  printLock: TRTLCriticalSection;
  printed: Integer;

function VariantCount(len, maxBytes: Int64): Int64;
begin
  if len > maxBytes then Result := maxBytes * 8 + len else Result := len * 8 + len;
end;

procedure RunItems(var c: TVariantCounts);
var i: LongInt; v: Int64; r: Integer; what: string;
begin
  repeat
    i := InterLockedIncrement(next) - 1;
    if i >= Length(items) then Break;
    for v := items[i].first to items[i].last do begin
      Inc(c.variants);
      r := fnRun(items[i].k, v, what);
      if r and CV_TAKEN <> 0 then Inc(c.taken);
      if r and CV_SAME <> 0 then Inc(c.same);
      if r and CV_FAILURE <> 0 then begin
        Inc(c.failures);
        EnterCriticalSection(printLock);
        try
          Inc(printed);
          if printed <= 20 then Writeln('  FAIL ', what);
        finally
          LeaveCriticalSection(printLock);
        end;
      end;
    end;
  until False;
end;

procedure TWorker.Execute;
begin
  RunItems(counts);
end;

function RunVariants(const totals: array of Int64; fn: TVariantFn): TVariantCounts;
var k, n, i, threads: Integer; v: Int64; w: array of TWorker;
begin
  items := nil;
  n := 0;
  for k := 0 to High(totals) do begin
    v := 0;
    while v < totals[k] do begin
      if n = Length(items) then SetLength(items, 2 * n + 64);
      items[n].k := k; items[n].first := v; items[n].last := v + CHUNK - 1;
      if items[n].last >= totals[k] then items[n].last := totals[k] - 1;
      Inc(n); Inc(v, CHUNK);
    end;
  end;
  SetLength(items, n);
  next := 0; fnRun := fn; printed := 0;
  threads := StrToIntDef(GetEnvironmentVariable('PJA_TEST_THREADS'), CpuCount);
  if threads < 1 then threads := 1;
  if threads > 64 then threads := 64;
  FillChar(Result, SizeOf(Result), 0);
  InitCriticalSection(printLock);
  w := nil;
  SetLength(w, threads - 1);
  for i := 0 to High(w) do w[i] := TWorker.Create(False);
  RunItems(Result);
  for i := 0 to High(w) do begin
    w[i].WaitFor;
    Inc(Result.variants, w[i].counts.variants);
    Inc(Result.taken, w[i].counts.taken);
    Inc(Result.same, w[i].counts.same);
    Inc(Result.failures, w[i].counts.failures);
    w[i].Free;
  end;
  DoneCriticalSection(printLock);
end;

end.
