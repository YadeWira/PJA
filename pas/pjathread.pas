{ Threads the main thread can wait for without a nap.

  FreePascal's TThread.WaitFor, on Unix and called from the main thread,
  polls: CheckSynchronize(100) until the thread is finished, and nothing
  wakes that wait when a thread merely ends. So it returned up to 100 ms
  after the thread did. The command codes on the main thread (one file, or
  the last of several) and waits there for its bands' threads: `pja a -th 2`
  on a 15 KB one-band photo took 110 ms instead of 33 (the live check's two
  threads), and every RunBands, head and worker pool paid the same.

  TJoinThread sets an event once the thread is done (DoTerminate, which
  the RTL calls after setting Finished), and Join waits for it before
  WaitFor, which then joins at once. Only the waiting changes: no value. }
unit pjathread;

{$I pja.inc}
{$ifopt R-}{$fatal pjathread: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjathread: overflow checks ($Q+) are mandatory}{$endif}

interface

uses Classes;

type
  TJoinThread = class(TThread)
  private
    doneEvent: PRTLEvent;
  protected
    procedure DoTerminate; override;
  public
    constructor Create(CreateSuspended: Boolean);
    destructor Destroy; override;
    { WaitFor without its 100 ms naps; only for a thread that was started }
    procedure Join;
  end;

implementation

constructor TJoinThread.Create(CreateSuspended: Boolean);
begin
  { before the thread exists: started at once, it may end before the
    inherited constructor returns }
  doneEvent := RTLEventCreate;
  inherited Create(CreateSuspended);
end;

destructor TJoinThread.Destroy;
begin
  inherited Destroy;
  if doneEvent <> nil then RTLEventDestroy(doneEvent);
  doneEvent := nil;
end;

procedure TJoinThread.DoTerminate;
begin
  inherited DoTerminate;
  RTLEventSetEvent(doneEvent);
end;

procedure TJoinThread.Join;
begin
  { the event stays set once set: a thread already done does not wait }
  if GetCurrentThreadID = MainThreadID then RTLEventWaitFor(doneEvent);
  WaitFor;
end;

end.
