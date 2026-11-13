unit pjaconsole;

{ pjaconsole.pas: what PJA prints, in UTF-8 everywhere (from PAIA's paiaconsole, 2d81235).

  The program runs in UTF-8 (pjacli's ReadArgs), but on Windows the RTL
  opens the standard output and error with the console's code page: a
  name with a character outside it ("動画.gif" in a Western console) was
  printed as "?", and in a file or a pipe as that code page's bytes, not
  UTF-8. Here, each of the four standard texts (Output, StdOut, ErrOutput,
  StdErr), on its own:
    - to a console: written with WriteConsoleW, so every character shows,
      and the console's code page is left as it was (changing it would
      stay changed if the program were cut short);
    - to anything else (a file, a pipe): UTF-8, the same bytes on every
      Windows, so another program reads --json and report the same.
  Elsewhere the texts are already UTF-8: SetupStdText does nothing.

  FreePascal opens those texts again in every thread (InitThread calls
  SysInitStdio): SetupStdText is called in the main thread and at the
  start of every thread that writes. }

{$I pja.inc}
{$ifopt R-}{$fatal pjaconsole: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjaconsole: overflow checks ($Q+) are mandatory}{$endif}

interface

procedure SetupStdText;

implementation

{$ifdef MSWINDOWS}
uses Windows;

{ The text's buffer, as UTF-8, to the console. A character cut between two
  buffers keeps its first bytes in UserData (count in [1], bytes in [2..4])
  until the rest comes. }
procedure ConsoleWrite(var t: TextRec);
var buf: array of Byte; w: array of WideChar; pend, n, total, keep, j, need: SizeInt;
    wn, done: Integer; written: DWORD;
begin
  n := t.BufPos;
  t.BufPos := 0;
  pend := t.UserData[1];
  if pend > 3 then pend := 0;
  total := pend + n;
  if total = 0 then Exit;
  SetLength(buf, total);
  for j := 0 to pend - 1 do buf[j] := t.UserData[2 + j];
  if n > 0 then Move(t.BufPtr^, buf[pend], n);
  { the last character complete? }
  keep := 0;
  j := total - 1;
  while (j >= 0) and (total - j < 4) and ((buf[j] and $C0) = $80) do Dec(j);
  if (j >= 0) and (buf[j] >= $C0) then begin
    if buf[j] < $E0 then need := 2 else if buf[j] < $F0 then need := 3 else need := 4;
    if total - j < need then keep := total - j;
  end;
  t.UserData[1] := keep;
  for j := 0 to keep - 1 do t.UserData[2 + j] := buf[total - keep + j];
  total := total - keep;
  if total = 0 then Exit;
  SetLength(w, total);
  wn := MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(@buf[0]), total, PWideChar(@w[0]), total);
  if wn <= 0 then begin InOutRes := 101; Exit; end;
  done := 0;
  while done < wn do begin
    if not WriteConsoleW(t.Handle, @w[done], wn - done, written, nil) or (written = 0) then begin
      InOutRes := 101;
      Exit;
    end;
    done := done + Integer(written);
  end;
end;

procedure SetupOne(var f: Text);
var mode: DWORD;
begin
  if TextRec(f).Mode <> fmOutput then Exit;
  Flush(f);
  SetTextCodePage(f, CP_UTF8);
  if GetConsoleMode(TextRec(f).Handle, mode) then begin
    TextRec(f).UserData[1] := 0;
    TextRec(f).InOutFunc := @ConsoleWrite;
    TextRec(f).FlushFunc := @ConsoleWrite;
  end;
end;

procedure SetupStdText;
begin
  SetupOne(Output);
  SetupOne(StdOut);
  SetupOne(ErrOutput);
  SetupOne(StdErr);
end;
{$else}
procedure SetupStdText;
begin
end;
{$endif}

end.
