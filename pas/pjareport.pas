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
  cut to keep the link under MAX_URL with a note to paste the rest. }
function IssueUrl(const title, report: string): string;
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

{ an argument as it may be shown: a path loses its folders }
function Shown(const a: string): string;
var k: Integer;
begin
  Result := a;
  k := LastDelimiter('/\', a);
  if (k > 0) and (k < Length(a)) and (Copy(a, 1, 1) <> '-') then Result := Copy(a, k + 1, MaxInt);
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
  if Length(title) > 200 then title := Copy(title, 1, 200);
end;

function IssueUrl(const title, report: string): string;
const NOTE = LineEnding + '[cut: the link has room for this much; paste the whole report from pja report]' + LineEnding;
var sl: TStringList; base, body, line: string; i, room: Integer;
begin
  base := NEW_ISSUE_URL + '&title=' + UrlEncode(title) + '&body=';
  room := MAX_URL - Length(base) - Length(UrlEncode(NOTE));
  sl := TStringList.Create;
  try
    sl.Text := report;
    body := '';
    for i := 0 to sl.Count - 1 do begin
      line := UrlEncode(sl[i] + LineEnding);
      if Length(body) + Length(line) > room then begin
        body := body + UrlEncode(NOTE);
        Break;
      end;
      body := body + line;
    end;
  finally
    sl.Free;
  end;
  Result := base + body;
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
