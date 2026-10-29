{ How many processors this process may use. FreePascal 3.2's
  TThread.ProcessorCount says 1 on every Unix, so the command's default
  (every processor, up to 8) was one thread on Linux and macOS: here Linux
  counts the CPUs of the process's affinity mask (what a container or
  taskset leaves it), other Unixes ask sysconf, and Windows keeps the RTL's
  answer, which is right there. }
unit pjacpu;
{$I pja.inc}

interface

function CpuCount: Integer;

implementation

uses Classes {$ifdef UNIX}, ctypes{$endif};

{$ifdef UNIX}
function sysconf(name: cint): clong; cdecl; external 'c';
{$ifdef LINUX}
function sched_getaffinity(pid: cint; size: csize_t; mask: Pointer): cint; cdecl; external 'c';
const SC_NPROCESSORS_ONLN = 84;
{$else}
{ macOS and the BSDs }
const SC_NPROCESSORS_ONLN = 58;
{$endif}
{$endif}

function CpuCount: Integer;
{$ifdef LINUX}
var mask: array[0..127] of Byte; i, b: Integer;
{$endif}
begin
  Result := 0;
  {$ifdef LINUX}
  FillChar(mask, SizeOf(mask), 0);
  if sched_getaffinity(0, SizeOf(mask), @mask) = 0 then
    for i := 0 to High(mask) do
      for b := 0 to 7 do
        if mask[i] and (1 shl b) <> 0 then Inc(Result);
  {$endif}
  {$ifdef UNIX}
  if Result < 1 then Result := sysconf(SC_NPROCESSORS_ONLN);
  {$else}
  Result := TThread.ProcessorCount;
  {$endif}
  if Result < 1 then Result := 1;
end;

end.
