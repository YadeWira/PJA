{ libpja: PJA as a shared library with a C interface (pja.h), for archivers
  and other programs.

    pas/lib/build.sh <out dir>   -> pja.so / pja.dll / pja.dylib

  Built with the C part (pas/build_c.sh, position-independent), the filter
  (pjafilter.c) and the 7-Zip codec plugin (pja7z.c). pja_compress and
  pja_decompress are pjapack's Pack and Unpack (a .pja, stream version 7);
  the filter is C, and calls back here for memory and for the codec on each
  file it finds. The same file is a 7-Zip / 7-Zip-zstd plugin: the
  functions 7-Zip looks for (GetNumberOfMethods, GetMethodProperty,
  CreateDecoder, CreateEncoder, CreateObject, GetModuleProp) are pja7z.c's,
  exported from here. No exception leaves the library: every export
  catches them and returns an error code. }
library pja;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  Classes, SysUtils, pjacodec, pjapack, pjaformat, pjablake3, pjacpu, pjav7, pjamodel;

{$L pjafilter.o}
{$L pja7z.o}

const
  PJA_OK = 0;
  PJA_E_NOT_TAKEN = 1;
  PJA_E_DATA = 2;
  PJA_E_MEMORY = 3;
  PJA_E_ARG = 6;
  { pja_decompress's own cap on an original's size }
  MAX_ORIGINAL = QWord(1) shl 31;
  VERSION_TEXT: PChar = 'pja ' + PJA_VERSION;

type
  { pjafilter.c's host_t }
  {$packrecords c}
  { pjafilter.c's job_t: a file to compress, or a stream to decompress }
  TJob = record
    input: PByte;
    size, expected: SizeUInt;
    output: PByte;
    outSize: SizeUInt;
    ok, threads: LongInt;
    done: LongInt;
  end;
  PJob = ^TJob;
  { pjafilter.c's host_t }
  THost = record
    alloc: function(size: SizeUInt): Pointer; cdecl;
    release: procedure(p: Pointer); cdecl;
    poolOpen: function(threads, encode: LongInt): Pointer; cdecl;
    poolSubmit: procedure(pool: Pointer; job: PJob); cdecl;
    poolWait: procedure(pool: Pointer; job: PJob); cdecl;
    poolClose: procedure(pool: Pointer); cdecl;
  end;
  {$packrecords default}
  TReadFn = function(ctx, buf: Pointer; size: SizeUInt): PtrInt; cdecl;
  TWriteFn = function(ctx: Pointer; buf: Pointer; size: SizeUInt): LongInt; cdecl;

procedure pjafilter_host(constref h: THost); cdecl; external;
function pjafilter_encode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
  threads: LongInt): LongInt; cdecl; external;
function pjafilter_decode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
  threads: LongInt): LongInt; cdecl; external;
function pjafilter2_encode(read: TReadFn; readCtx: Pointer; writeA: TWriteFn; aCtx: Pointer;
  writeB: TWriteFn; bCtx: Pointer; threads: LongInt): LongInt; cdecl; external;
function pjafilter2_decode(readA: TReadFn; aCtx: Pointer; readB: TReadFn; bCtx: Pointer;
  write: TWriteFn; writeCtx: Pointer; threads: LongInt): LongInt; cdecl; external;

type
  { pja7z.c's host7z_t }
  THost7z = record
    bstr: function(bytes: Pointer; len: LongWord): Pointer; cdecl;
    alloc: function(size: SizeUInt): Pointer; cdecl;
    release: procedure(p: Pointer); cdecl;
    threads: LongInt;
  end;
  { 7-Zip's calling convention for its exports and interfaces }
  HRESULT = LongInt;

procedure pja7z_host(constref h: THost7z); cdecl; external;
function pja7z_GetNumberOfMethods(n: PLongWord): HRESULT; cdecl; external;
function pja7z_GetMethodProperty(index, prop: LongWord; v: Pointer): HRESULT; cdecl; external;
function pja7z_CreateDecoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function pja7z_CreateEncoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function pja7z_CreateObject(clsid, iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function pja7z_GetModuleProp(prop: LongWord; v: Pointer): HRESULT; cdecl; external;

{$ifdef windows}
function SysAllocStringByteLen(s: Pointer; len: LongWord): Pointer; stdcall; external 'oleaut32.dll';

function MakeBstr(bytes: Pointer; len: LongWord): Pointer; cdecl;
begin
  Result := SysAllocStringByteLen(bytes, len);
end;
{$else}
function malloc(size: SizeUInt): Pointer; cdecl; external 'c';

{ 7-Zip's BSTR outside Windows (CPP/Common/MyWindows.cpp): from malloc, a
  32-bit byte count, the bytes, and two zero bytes; 7-Zip frees it }
function MakeBstr(bytes: Pointer; len: LongWord): Pointer; cdecl;
var p: PByte;
begin
  p := malloc(SizeUInt(len) + 4 + 4);
  if p = nil then Exit(nil);
  PLongWord(p)^ := len;
  Result := p + 4;
  if len > 0 then Move(bytes^, Result^, len);
  FillChar((p + 4 + len)^, 4, 0);
end;
{$endif}

function HostAlloc(size: SizeUInt): Pointer; cdecl;
begin
  try
    Result := GetMem(size);
  except
    Result := nil;
  end;
end;

procedure HostRelease(p: Pointer); cdecl;
begin
  FreeMem(p);
end;

{ bytes -> a fresh buffer for the caller, nil when there is no memory }
function Hand(const b: TBytes; out output: PByte; out outSize: SizeUInt): Boolean;
begin
  outSize := Length(b);
  output := HostAlloc(outSize + 1);
  Result := output <> nil;
  if Result and (outSize > 0) then Move(b[0], output^, outSize);
end;

function InBytes(input: PByte; size: SizeUInt): TBytes;
begin
  SetLength(Result, size);
  if size > 0 then Move(input^, Result[0], size);
end;

{ one of the filter's jobs. Encoding: the file as PJA's codec stream,
  not ok when PJA does not take it or would only keep it as bytes.
  Decoding: the file back. }
procedure RunJob(var j: TJob; encode: Boolean; threads: Integer);
var b: TBytes; r: TCodecResult;
begin
  j.output := nil; j.outSize := 0; j.ok := 0;
  try
    if encode then begin
      r := Compress(InBytes(j.input, j.size), b, True, threads, False, True, True);
      if not r.Ok or r.asBytes then Exit;
    end else
      if not Decompress(InBytes(j.input, j.size), b, SizeInt(j.expected), threads, SizeInt(j.expected)).Ok then
        Exit;
    if Hand(b, j.output, j.outSize) then j.ok := 1;
  except
    if j.output <> nil then FreeMem(j.output);
    j.output := nil; j.ok := 0;
  end;
end;

type
  { the filter's pool: threads that take the jobs in the order they come
    and run them; the filter waits for each one in its own order }
  TPool = class;
  TPoolThread = class(TThread)
    pool: TPool;
    procedure Execute; override;
  end;
  TPool = class
    lock: TRTLCriticalSection;
    work, finished: PRTLEvent;
    queue: array of PJob;
    head, count: Integer;
    stop, encode: Boolean;
    workers: array of TPoolThread;
    function Take(out j: PJob): Boolean;
  end;

{ the next job, or nil; False when the pool is closing and nothing is left }
function TPool.Take(out j: PJob): Boolean;
begin
  EnterCriticalSection(lock);
  j := nil;
  if head < count then begin j := queue[head]; Inc(head); end;
  if head = count then begin head := 0; count := 0; end;
  Result := (j <> nil) or not stop;
  LeaveCriticalSection(lock);
end;

procedure TPoolThread.Execute;
var j: PJob;
begin
  while pool.Take(j) do
    if j = nil then RTLEventWaitFor(pool.work, 20)
    else begin
      RunJob(j^, pool.encode, j^.threads);
      InterLockedExchange(j^.done, 1);
      RTLEventSetEvent(pool.finished);
    end;
  ReleaseThreadModels;
end;

function OpenPool(threads, encode: LongInt): Pointer; cdecl;
var p: TPool; k: Integer;
begin
  Result := nil;
  try
    if threads < 1 then threads := 1;
    p := TPool.Create;
    InitCriticalSection(p.lock);
    p.work := RTLEventCreate;
    p.finished := RTLEventCreate;
    p.encode := encode <> 0;
    SetLength(p.queue, 64);
    SetLength(p.workers, threads);
    for k := 0 to threads - 1 do begin
      p.workers[k] := TPoolThread.Create(True);
      p.workers[k].pool := p;
      p.workers[k].Start;
    end;
    Result := p;
  except
    Result := nil;
  end;
end;

procedure SubmitJob(pool: Pointer; job: PJob); cdecl;
var p: TPool;
begin
  p := TPool(pool);
  EnterCriticalSection(p.lock);
  if p.count = Length(p.queue) then SetLength(p.queue, 2 * Length(p.queue));
  p.queue[p.count] := job;
  Inc(p.count);
  LeaveCriticalSection(p.lock);
  RTLEventSetEvent(p.work);
end;

procedure WaitJob(pool: Pointer; job: PJob); cdecl;
begin
  while InterLockedCompareExchange(job^.done, 1, 1) = 0 do
    RTLEventWaitFor(TPool(pool).finished, 20);
end;

procedure ClosePool(pool: Pointer); cdecl;
var p: TPool; k: Integer;
begin
  p := TPool(pool);
  EnterCriticalSection(p.lock);
  p.stop := True;
  LeaveCriticalSection(p.lock);
  for k := 0 to High(p.workers) do begin
    RTLEventSetEvent(p.work);
    p.workers[k].WaitFor;
    p.workers[k].Free;
  end;
  RTLEventDestroy(p.work);
  RTLEventDestroy(p.finished);
  DoneCriticalSection(p.lock);
  p.Free;
end;

function pja_version: PChar; cdecl;
begin
  Result := VERSION_TEXT;
end;

function pja_compress(input: PByte; size: SizeUInt; out output: PByte; out outSize: SizeUInt;
                      threads: LongInt): LongInt; cdecl;
var pja: TBytes; r: TPackResult;
begin
  output := nil; outSize := 0;
  if (input = nil) and (size > 0) then Exit(PJA_E_ARG);
  if threads < 1 then threads := 1;
  try
    r := Pack(InBytes(input, size), pja, threads, False, True, '', True);
    if not r.Ok or r.codec.asBytes then Exit(PJA_E_NOT_TAKEN);
    if Hand(pja, output, outSize) then Result := PJA_OK else Result := PJA_E_MEMORY;
  except
    Result := PJA_E_MEMORY;
  end;
end;

function pja_decompress(input: PByte; size: SizeUInt; out output: PByte; out outSize: SizeUInt;
                        maxSize: SizeUInt; threads: LongInt): LongInt; cdecl;
var original: TBytes; expected: THash16; r: TPackResult; cap: QWord;
begin
  output := nil; outSize := 0;
  if (input = nil) and (size > 0) then Exit(PJA_E_ARG);
  if threads < 1 then threads := 1;
  cap := MAX_ORIGINAL;
  if (maxSize > 0) and (maxSize < cap) then cap := maxSize;
  try
    r := Unpack(InBytes(input, size), cap, original, expected, threads);
    if r.err = ukTooLarge then Exit(PJA_E_MEMORY);
    if not r.Ok then Exit(PJA_E_DATA);
    if Hand(original, output, outSize) then Result := PJA_OK else Result := PJA_E_MEMORY;
  except
    Result := PJA_E_MEMORY;
  end;
end;

procedure pja_free(p: Pointer); cdecl;
begin
  FreeMem(p);
end;

function pja_filter_encode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
                           threads: LongInt): LongInt; cdecl;
begin
  try
    Result := pjafilter_encode(read, readCtx, write, writeCtx, threads);
  except
    Result := PJA_E_MEMORY;
  end;
end;

function pja_filter_decode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
                           threads: LongInt): LongInt; cdecl;
begin
  try
    Result := pjafilter_decode(read, readCtx, write, writeCtx, threads);
  except
    Result := PJA_E_MEMORY;
  end;
end;

function pja_filter2_encode(read: TReadFn; readCtx: Pointer; writeA: TWriteFn; aCtx: Pointer;
                            writeB: TWriteFn; bCtx: Pointer; threads: LongInt): LongInt; cdecl;
begin
  try
    Result := pjafilter2_encode(read, readCtx, writeA, aCtx, writeB, bCtx, threads);
  except
    Result := PJA_E_MEMORY;
  end;
end;

function pja_filter2_decode(readA: TReadFn; aCtx: Pointer; readB: TReadFn; bCtx: Pointer;
                            write: TWriteFn; writeCtx: Pointer; threads: LongInt): LongInt; cdecl;
begin
  try
    Result := pjafilter2_decode(readA, aCtx, readB, bCtx, write, writeCtx, threads);
  except
    Result := PJA_E_MEMORY;
  end;
end;

{ the 7-Zip plugin's exports: STDAPI, __stdcall on Windows x86 }
function GetNumberOfMethods(n: PLongWord): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := pja7z_GetNumberOfMethods(n);
end;

function GetMethodProperty(index, prop: LongWord; v: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := pja7z_GetMethodProperty(index, prop, v);
end;

function CreateDecoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := pja7z_CreateDecoder(index, iid, obj);
end;

function CreateEncoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := pja7z_CreateEncoder(index, iid, obj);
end;

function CreateObject(clsid, iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := pja7z_CreateObject(clsid, iid, obj);
end;

function GetModuleProp(prop: LongWord; v: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := pja7z_GetModuleProp(prop, v);
end;

var host: THost; host7z: THost7z;

exports
  pja_version, pja_compress, pja_decompress, pja_free, pja_filter_encode, pja_filter_decode,
  pja_filter2_encode, pja_filter2_decode,
  GetNumberOfMethods, GetMethodProperty, CreateDecoder, CreateEncoder, CreateObject, GetModuleProp;

begin
  IsMultiThread := True;
  host.alloc := @HostAlloc;
  host.release := @HostRelease;
  host.poolOpen := @OpenPool;
  host.poolSubmit := @SubmitJob;
  host.poolWait := @WaitJob;
  host.poolClose := @ClosePool;
  pjafilter_host(host);
  host7z.bstr := @MakeBstr;
  host7z.alloc := @HostAlloc;
  host7z.release := @HostRelease;
  host7z.threads := CpuCount;
  if host7z.threads > 8 then host7z.threads := 8;
  pja7z_host(host7z);
end.
