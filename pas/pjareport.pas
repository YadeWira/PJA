{ pja report (doc/CLI.md): a bug report in plain text, and a link that
  opens a GitHub issue with it.

  The report: PJA's version and build, the system, the processor and the
  SIMD path, the threads; the command line; and for the file, its size,
  its BLAKE3-128, what PJA does with it and its structure (pjainfo).

  Privacy: no pixels, no metadata contents (EXIF, XMP, ICC, comments: only
  their sizes), no folders (a name only, never its path). The file itself
  goes only with --with-file, copied beside the report for the person to
  attach, and only if they choose to. }
unit pjareport;

{$I pja.inc}
{$ifopt R-}{$fatal pjareport: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pjareport: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

const
  NEW_ISSUE_URL = 'https://github.com/YadeWira/PJA/issues/new?template=bug_report.yml';
  { a link GitHub and the browsers take whole }
  MAX_URL = 6000;

{ The report. fileName '' for one without a file; args: the command line,
  without the program. title: a one-line summary for the issue. }
function BuildReport(const fileName: string; const data: TBytes; const args: array of string; threads: Integer;
                     maxOutput: QWord; out title: string): string;
{ The link to a new issue with that title and the report as its body,
  kept under MAX_URL: a report too long for it keeps its start (PJA, the
  system, the command) and its end (the frame, the problems, the metadata
  sizes, what PJA does), with a note in their place to paste the whole
  report; cut says so. }
function IssueUrl(const title, report: string; out cut: Boolean): string;
{ percent-encoding of everything but A-Z a-z 0-9 - _ . ~ }
function UrlEncode(const s: string): string;
{ A copy of the file beside the report (dir: the report's folder, '' for
  the current one), named pja-report-NAME; never over an existing file.
  The path written, or '' and why in msg. }
function CopyBeside(const fileName: string; const data: TBytes; const dir: string; out msg: string): string;

implementation

uses Classes, pjablake3, pjacodec, pjainfo, pjasysinfo, pjafs;

function UrlEncode(const s: string): string;
var i: Integer; c: Char;
begin
  Result := '';
  for i := 1 to Length(s) do begin
    c := s[i];
    if c in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'] then Result := Result + c
    else Result := Result + '%' + IntToHex(Ord(c), 2);
  end;
end;

{ an argument as it may be shown: a path loses its folders, the value of
  an option written --name=PATH too. No option has a / or \ in its name,
  so one that starts with - and has them (a file after --) is a path. }
function Shown(const a: string): string;
var k, eq: Integer;
begin
  Result := a;
  eq := Pos('=', a);
  if (Copy(a, 1, 2) = '--') and (eq > 2) and (LastDelimiter('/\', Copy(a, 1, eq)) = 0) then
    Exit(Copy(a, 1, eq) + Shown(Copy(a, eq + 1, MaxInt)));
  { a folder written with its final / is a folder all the same }
  while (Length(Result) > 1) and (Result[Length(Result)] in ['/', '\']) do SetLength(Result, Length(Result) - 1);
  k := LastDelimiter('/\', Result);
  if (k > 0) and (k < Length(Result)) then Result := Copy(Result, k + 1, MaxInt);
end;

{ s cut to at most n bytes, not inside a UTF-8 sequence }
function CutUtf8(const s: string; n: Integer): string;
begin
  if Length(s) <= n then Exit(s);
  { a byte 10xxxxxx continues the sequence before it: cut before its lead }
  while (n > 0) and (Ord(s[n + 1]) and $C0 = $80) do Dec(n);
  Result := Copy(s, 1, n);
end;

function BuildReport(const fileName: string; const data: TBytes; const args: array of string; threads: Integer;
                     maxOutput: QWord; out title: string): string;
var sl: TStringList; n, act: TInfoNode; cmd, name: string; i: Integer;
begin
  sl := TStringList.Create;
  try
    sl.Add('PJA bug report');
    sl.Add('(made by pja report: no pixels, no metadata contents, only sizes and the file''s structure)');
    sl.Add('');
    sl.Add('== PJA and the system');
    sl.Text := sl.Text + SystemText(True);
    sl.Add('threads: ' + IntToStr(threads));
    sl.Add('');
    sl.Add('== Command');
    cmd := 'pja';
    for i := 0 to High(args) do cmd := cmd + ' ' + Shown(args[i]);
    sl.Add(cmd);
    title := 'pja ' + PJA_VERSION + ': ';
    if fileName = '' then begin
      sl.Add('');
      sl.Add('== No file');
      title := title + '(describe the problem)';
    end else begin
      name := Shown(fileName);
      sl.Add('');
      sl.Add('== The file');
      sl.Add('blake3_128: ' + HexBytes(Blake3_128(data)));
      n := DescribeFile(name, data, True, threads, maxOutput);
      try
        act := n.Find('pja');
        if act <> nil then title := title + act.line + ' (' + ExtractFileExt(name) + ')';
        if n.Find('internal_error') <> nil then title := 'pja ' + PJA_VERSION + ': internal error: ' +
          n.Find('internal_error').value;
        n.Render(sl, 0);
      finally
        n.Free;
      end;
    end;
    Result := sl.Text;
  finally
    sl.Free;
  end;
  title := CutUtf8(title, 200);
end;

function IssueUrl(const title, report: string; out cut: Boolean): string;
const NOTE = '[%d lines cut here to fit the link: paste the whole report from pja report]';
var sl: TStringList; base, head, tail, line, mid: string; i, first, last, room, headRoom: Integer;
    enc: array of string; total: Int64;
begin
  base := NEW_ISSUE_URL + '&title=' + UrlEncode(title) + '&body=';
  cut := False;
  sl := TStringList.Create;
  try
    sl.Text := report;
    enc := nil;
    SetLength(enc, sl.Count);
    total := 0;
    for i := 0 to sl.Count - 1 do begin
      enc[i] := UrlEncode(sl[i] + LineEnding);
      Inc(total, Length(enc[i]));
    end;
    if Length(base) + total <= MAX_URL then begin
      head := '';
      for i := 0 to High(enc) do head := head + enc[i];
      Exit(base + head);
    end;
    cut := True;
    { the note at its longest (the count of lines it stands for) }
    room := MAX_URL - Length(base) - Length(UrlEncode(Format(NOTE, [sl.Count]) + LineEnding));
    { the start, up to half the room; then the end, as much as is left }
    headRoom := room div 2;
    head := ''; first := 0;
    while (first <= High(enc)) and (Length(head) + Length(enc[first]) <= headRoom) do begin
      head := head + enc[first];
      Inc(first);
    end;
    tail := ''; last := High(enc);
    while (last >= first) and (Length(head) + Length(tail) + Length(enc[last]) <= room) do begin
      tail := enc[last] + tail;
      Dec(last);
    end;
    mid := UrlEncode(Format(NOTE, [last - first + 1]) + LineEnding);
    line := head + mid + tail;
  finally
    sl.Free;
  end;
  Result := base + line;
end;

function CopyBeside(const fileName: string; const data: TBytes; const dir: string; out msg: string): string;
var path: string; r: TFsResult; o: TOutcome;
begin
  Result := '';
  msg := '';
  path := 'pja-report-' + ExtractFileName(fileName);
  if dir <> '' then path := IncludeTrailingPathDelimiter(dir) + path;
  r := WriteVerified(path, data, Blake3_128(data), omDelete, False, o);
  if not r.Ok then begin
    if r.code >= 0 then msg := path + ': could not write it: ' + SysErrorMessage(r.code) + ' (' + r.Text + ')'
    else msg := path + ': could not write it (' + r.Text + ')';
    Exit;
  end;
  if o.kind <> ocVerified then begin msg := path + ': did not verify'; Exit; end;
  Result := path;
end;

end.
