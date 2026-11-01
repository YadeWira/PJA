{ The libraries' memory on Windows: the process heap (HeapAlloc) in place
  of FreePascal's own heap. First in a library's uses, so that it is in
  place before the other units take memory.

  Why: FreePascal 3.2.2's heap, in a DLL, counts the threads that use it
  and deletes its lock (heap_lock) when the count comes back to zero. The
  thread that loads the DLL is the first in that count, and if it ends
  while the DLL stays loaded the count can reach zero: the lock is gone,
  and the next block freed by a thread other than the one that took it
  (every new thread frees one: its start record) enters a deleted
  critical section. 7-Zip's file manager (7zFM) loads its codecs from such
  a short-lived thread, and crashed in PJA's threads on testing or
  extracting from inside an archive (7z.exe and 7zG, which load them from
  their main thread, did not).

  Each block carries 16 bytes before it, its size and a mark, so that
  blocks stay aligned as the process heap gives them (16 bytes on x64, 8 on
  x86) and a block the runtime took before this unit started is told apart
  and given back to the manager that took it. }
unit pjaheap;

{$mode objfpc}

interface

implementation

{$ifdef windows}
const
  HEAP_ZERO_MEMORY = 8;
  HEADER = 16;
  OURS = PtrUInt({$ifdef cpu64}$9E3779B97F4A7C15{$else}$9E3779B9{$endif});

type
  PHeader = ^THeader;
  THeader = record
    size, mark: PtrUInt;
  end;

function GetProcessHeap: THandle; stdcall; external 'kernel32' name 'GetProcessHeap';
function HeapAlloc(heap: THandle; flags: LongWord; size: PtrUInt): Pointer; stdcall;
  external 'kernel32' name 'HeapAlloc';
function HeapReAlloc(heap: THandle; flags: LongWord; p: Pointer; size: PtrUInt): Pointer; stdcall;
  external 'kernel32' name 'HeapReAlloc';
function HeapFree(heap: THandle; flags: LongWord; p: Pointer): LongBool; stdcall;
  external 'kernel32' name 'HeapFree';

var
  heap: THandle;
  old: TMemoryManager;

function Mine(p: Pointer): Boolean; inline;
begin
  Result := PHeader(p - HEADER)^.mark = OURS;
end;

function Take(size: PtrUInt; flags: LongWord): Pointer;
var h: PHeader;
begin
  h := HeapAlloc(heap, flags, size + HEADER);
  if h = nil then Exit(nil);
  h^.size := size;
  h^.mark := OURS;
  Result := Pointer(h) + HEADER;
end;

function HGetMem(size: PtrUInt): Pointer;
begin
  Result := Take(size, 0);
end;

function HAllocMem(size: PtrUInt): Pointer;
begin
  Result := Take(size, HEAP_ZERO_MEMORY);
end;

function HFreeMem(p: Pointer): PtrUInt;
begin
  if p = nil then Exit(0);
  if not Mine(p) then Exit(old.FreeMem(p));
  Result := PHeader(p - HEADER)^.size;
  PHeader(p - HEADER)^.mark := 0;
  HeapFree(heap, 0, p - HEADER);
end;

function HFreeMemSize(p: Pointer; size: PtrUInt): PtrUInt;
begin
  Result := HFreeMem(p);
end;

function HMemSize(p: Pointer): PtrUInt;
begin
  if not Mine(p) then Exit(old.MemSize(p));
  Result := PHeader(p - HEADER)^.size;
end;

function HReAllocMem(var p: Pointer; size: PtrUInt): Pointer;
var h: PHeader; q: Pointer; n: PtrUInt;
begin
  if size = 0 then begin
    HFreeMem(p);
    p := nil;
  end else if p = nil then
    p := HGetMem(size)
  else if Mine(p) then begin
    h := HeapReAlloc(heap, 0, p - HEADER, size + HEADER);
    if h = nil then Exit(nil);
    h^.size := size;
    p := Pointer(h) + HEADER;
  end else begin
    q := HGetMem(size);
    if q = nil then Exit(nil);
    n := old.MemSize(p);
    if n > size then n := size;
    Move(p^, q^, n);
    old.FreeMem(p);
    p := q;
  end;
  Result := p;
end;

function HGetHeapStatus: THeapStatus;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function HGetFPCHeapStatus: TFPCHeapStatus;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

var
  mm: TMemoryManager;

initialization
  heap := GetProcessHeap;
  GetMemoryManager(old);
  mm := old;
  mm.NeedLock := False;
  mm.GetMem := @HGetMem;
  mm.FreeMem := @HFreeMem;
  mm.FreeMemSize := @HFreeMemSize;
  mm.AllocMem := @HAllocMem;
  mm.ReAllocMem := @HReAllocMem;
  mm.MemSize := @HMemSize;
  mm.GetHeapStatus := @HGetHeapStatus;
  mm.GetFPCHeapStatus := @HGetFPCHeapStatus;
  SetMemoryManager(mm);
{$endif}
end.
