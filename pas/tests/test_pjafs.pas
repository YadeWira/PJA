{ Writing the output without following links, without half-done writes and
  without leaving a file whose hash does not match under its name
  (doc/FORMAT.md 4.5).

    test_pjafs <temp_dir>   (pjafs_* is created and deleted inside) }
program test_pjafs;
{$I ../pja.inc}
{$ifopt R-}{$fatal test_pjafs: range checks ($R+) are mandatory}{$endif}
uses SysUtils, Classes, {$ifndef MSWINDOWS} BaseUnix, {$endif} pjablake3, pjafs;

var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:64, '  ok') else begin Inc(failures); Writeln('  ', what:64, '  FAIL'); end; end;

function B(const s: RawByteString): TBytes;
begin Result := nil; SetLength(Result, Length(s)); if s <> '' then Move(s[1], Result[0], Length(s)); end;
function H16(const s: RawByteString): THash16; begin Result := Blake3_128(B(s)); end;
function ReadText(const f: string): RawByteString; var st: TFileStream;
begin
  st := TFileStream.Create(f, fmOpenRead or fmShareDenyNone);
  try Result := ''; SetLength(Result, st.Size); if st.Size > 0 then st.ReadBuffer(Result[1], st.Size);
  finally st.Free; end;
end;
procedure PutText(const f: string; const s: RawByteString); var st: TFileStream;
begin
  st := TFileStream.Create(f, fmCreate);
  try if s <> '' then st.WriteBuffer(s[1], Length(s)); finally st.Free; end;
end;
function Exists(const p: string): Boolean;
{$ifndef MSWINDOWS} var st: Stat; {$endif}
begin {$ifdef MSWINDOWS} Result := FileExists(p) or DirectoryExists(p); {$else} Result := fpLstat(PChar(p), st) = 0; {$endif} end;
function IsLink(const p: string): Boolean;
{$ifndef MSWINDOWS} var st: Stat; {$endif}
begin {$ifdef MSWINDOWS} Result := False; {$else} Result := (fpLstat(PChar(p), st) = 0) and fpS_ISLNK(st.st_mode); {$endif} end;
procedure MakeLink(const target, p: string);
begin {$ifndef MSWINDOWS} if fpSymlink(PChar(target), PChar(p)) <> 0 then raise Exception.Create('symlink ' + p); {$endif} end;

procedure DeleteTree(const d: string);
var sr: TSearchRec;
begin
  if IsLink(d) then begin DeleteFile(d); Exit; end;
  if FindFirst(IncludeTrailingPathDelimiter(d) + '*', faAnyFile or faSymLink, sr) = 0 then begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      if IsLink(IncludeTrailingPathDelimiter(d) + sr.Name) then DeleteFile(IncludeTrailingPathDelimiter(d) + sr.Name)
      else if (sr.Attr and faDirectory) <> 0 then DeleteTree(IncludeTrailingPathDelimiter(d) + sr.Name)
      else DeleteFile(IncludeTrailingPathDelimiter(d) + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  RemoveDir(d);
end;

var TMP: string;
function TempDir(const name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(TMP) + 'pjafs_' + name;
  DeleteTree(Result);
  if not ForceDirectories(Result) then raise Exception.Create('could not create ' + Result);
end;
var d, outside: string; q: RawByteString; f: TFsResult;
    oc: TOutcome; i: Integer; foreign, hGood: THash16; pid: Int64; note: RawByteString; dead: string;
const TEMP_DIRS: array[0..13] of string = ('verify', 'keep', 'final_outside', 'final_outside_x', 'dangling',
        'dangling_x', 'hard', 'hard_x', 'foreign', 'corrupt_link', 'dirs', 'long', 'left', 'left_clean');

{ a file of `age` seconds }
procedure PutOld(const f: string; age: Integer);
begin
  PutText(f, 'left');
  if FileSetDate(f, DateTimeToFileDate(Now - age / 86400)) <> 0 then raise Exception.Create('FileSetDate ' + f);
end;

begin
  cells := 0; failures := 0;
  if ParamCount < 1 then begin Writeln('usage: test_pjafs <temp_dir>'); Halt(2); end;
  TMP := ParamStr(1);

  Writeln('--- Parent: Path::parent');
  { Parent returned garbage on the normal path (Result := True was missing):
    in this binary it gave false 1000 out of 1000 times when called directly. }
  Check(Parent('x', q) and (q = ''), 'x -> empty, like Path::parent');
  Check(not Parent('', q), 'empty has no parent');
  Check(Parent('a/b', q) and (q = 'a'), 'relative: a/b -> a');
  {$ifndef MSWINDOWS}
  Check(Parent('/a/b/c', q) and (q = '/a/b'), '/a/b/c -> /a/b');
  Check(Parent('/a', q) and (q = '/'), '/a -> /');
  Check(not Parent('/', q), '/ has no parent');
  Check(Parent('a\b', q) and (q = ''), 'on Unix the backslash is part of the name');
  {$else}
  Check(Parent('C:\a\b', q) and (q = 'C:\a'), 'C:\a\b -> C:\a');
  Check(Parent('C:\a', q) and (q = 'C:\'), 'C:\a -> C:\');
  Check(not Parent('C:\', q), 'C:\ has no parent');
  { the path is typed by the user: on Windows '/' separates too }
  Check(Parent('C:/a/b', q) and (q = 'C:/a'), 'C:/a/b -> C:/a');
  Check(Parent('C:/a', q) and (q = 'C:/'), 'C:/a -> C:/');
  Check(not Parent('C:/', q), 'C:/ has no parent');
  Check(Parent('dir\sub/x.jpg', q) and (q = 'dir\sub'), 'mixed separators');
  Check(Parent('\\?\C:\a', q) and (q = '\\?\C:\'), '\\?\C:\a -> the root');
  Check(Parent('\\?\UNC\srv\share\a', q) and (q = '\\?\UNC\srv\share\'), 'UNC: \\srv\share\a -> \\srv\share\');
  Check(not Parent('\\srv\share\', q), 'UNC without prefix: the share is the root');
  {$endif}

  Writeln('--- a_hash_that_does_not_match_leaves_no_file_under_its_name');
  d := TempDir('verify');
  f := WriteVerified(d + '/ok.jpg', B('correct contents'), H16('correct contents'), omDelete, False, oc);
  Check(f.Ok and (oc.kind = ocVerified) and (oc.path = d + '/ok.jpg'), 'positive control: Verified');
  Check(ReadText(d + '/ok.jpg') = 'correct contents', 'the good case stays on disk');
  Check(not Exists(d + '/' + TempName(0)), '  through a temporary, not left behind');
  foreign := H16('something else');
  f := WriteVerified(d + '/bad.jpg', B('correct contents'), foreign, omDelete, False, oc);
  Check(f.Ok and (oc.kind = ocDeleted), 'foreign hash: Deleted');
  hGood := H16('correct contents');
  Check(CompareMem(@oc.expected, @foreign, 16) and CompareMem(@oc.actual, @hGood, 16),
     'expected and actual are right');
  Check(not Exists(d + '/bad.jpg'), 'the file with a bad hash was not left under its name');
  f := WriteVerified(d + '/empty.jpg', nil, H16(''), omDelete, False, oc);
  Check(f.Ok and (oc.kind = ocVerified) and Exists(d + '/empty.jpg'), 'zero bytes: created and verified');

  Writeln('--- keep_renames_and_never_leaves_the_good_name');
  d := TempDir('keep');
  f := WriteVerified(d + '/photo.jpg', B('salvageable bytes'), foreign, omKeep, False, oc);
  Check(f.Ok and (oc.kind = ocKept) and (ExtractFileName(oc.path) = 'photo.jpg.corrupt'), 'Kept as photo.jpg.corrupt');
  Check(ReadText(d + '/photo.jpg.corrupt') = 'salvageable bytes', 'the bytes survive');
  Check(not Exists(d + '/photo.jpg'), 'the good name stays free');
  f := WriteVerified(d + '/photo.jpg', B('another try'), foreign, omKeep, False, oc);
  Check(f.Ok and (ExtractFileName(oc.path) = 'photo.jpg.corrupt.1'), 'the second one goes to .corrupt.1');
  Check(not Exists(d + '/photo.jpg'), 'and the good name is still free');
  Check(ReadText(d + '/photo.jpg.corrupt') = 'salvageable bytes', 'the first .corrupt is not overwritten');

  Writeln('--- without_overwrite_a_foreign_file_stays_intact');
  d := TempDir('foreign');
  PutText(d + '/f.jpg', 'the user''s');
  f := WriteVerified(d + '/f.jpg', B('x'), H16('x'), omDelete, False, oc);
  Check(not f.Ok, 'does not write: ' + f.Text);
  Check(ReadText(d + '/f.jpg') = 'the user''s', 'the user''s file stays intact');
  f := WriteVerified(d + '/f.jpg', B('bad'), H16('other'), omDelete, True, oc);
  Check(f.Ok and (oc.kind = ocDeleted) and (ReadText(d + '/f.jpg') = 'the user''s'),
     'with overwrite and a foreign hash: the user''s stays intact');
  f := WriteVerified(d + '/f.jpg', B('bad'), H16('other'), omKeep, True, oc);
  Check(f.Ok and (oc.kind = ocKept) and (ReadText(d + '/f.jpg') = 'the user''s')
     and (ReadText(d + '/f.jpg.corrupt') = 'bad'), '  and with keep, too: it goes to .corrupt');
  f := WriteVerified(d + '/f.jpg', B('x'), H16('x'), omDelete, True, oc);
  Check(f.Ok and (ReadText(d + '/f.jpg') = 'x'), 'with overwrite: replaces it');
  Check(not Exists(d + '/' + TempName(0)), '  without leaving the temporary');
  PutText(d + '/' + TempName(0), 'taken');
  f := WriteVerified(d + '/g.jpg', B('y'), H16('y'), omDelete, True, oc);
  Check(f.Ok and (ReadText(d + '/g.jpg') = 'y') and (ReadText(d + '/' + TempName(0)) = 'taken'),
     '  with temporary 0 taken, it uses another and does not touch it');
  f := WriteVerified(d + '/h.jpg', B('z'), H16('z'), omDelete, False, oc);
  Check(f.Ok and (ReadText(d + '/h.jpg') = 'z') and (ReadText(d + '/' + TempName(0)) = 'taken')
     and not Exists(d + '/' + TempName(1)), '  and without overwrite too');
  ForceDirectories(d + '/folder.jpg');
  f := WriteVerified(d + '/folder.jpg', B('x'), H16('x'), omDelete, True, oc);
  Check((not f.Ok) and DirectoryExists(d + '/folder.jpg'), 'over a directory, not even with overwrite: ' + f.Text);

  Writeln('--- intermediate directories');
  d := TempDir('dirs');
  f := WriteVerified(d + '/a/b/c/x.jpg', B('x'), H16('x'), omDelete, False, oc);
  Check(f.Ok and (ReadText(d + '/a/b/c/x.jpg') = 'x'), 'creates the missing ones');
  PutText(d + '/file', 'x');
  f := WriteVerified(d + '/file/x.jpg', B('x'), H16('x'), omDelete, False, oc);
  Check(not f.Ok, 'a file in place of a directory: ' + f.Text);
  if not SetCurrentDir(d) then raise Exception.Create('chdir');
  f := WriteVerified('rel.jpg', B('r'), H16('r'), omDelete, False, oc);
  Check(f.Ok and (ReadText(d + '/rel.jpg') = 'r'), 'relative path, no directory');
  f := WriteVerified('sub/rel.jpg', B('r'), H16('r'), omDelete, False, oc);
  Check(f.Ok and (ReadText(d + '/sub/rel.jpg') = 'r'), 'relative path with a directory');
  SetCurrentDir(TMP);

  Writeln('--- the temporary name: PJA''s own pattern, with the pid');
  Check(IsTempName('.pja-tmp-123-0', pid) and (pid = 123), '.pja-tmp-123-0: pid 123');
  Check(IsTempName('.pja-tmp-4294967295-999', pid) and (pid = 4294967295), '  the largest pid, the last try');
  Check(IsTempName('.pja-tmp7', pid) and (pid = 0), '.pja-tmp7 (0.9.0 and earlier): no pid');
  Check(IsTempName(TempName(5), pid) and (pid = GetProcessID), 'TempName carries this process''s pid');
  Check(not IsTempName('.pja-tmp', pid) and not IsTempName('.pja-tmp-12', pid) and not IsTempName('.pja-tmp-1-', pid)
     and not IsTempName('.pja-tmp-01-0', pid) and not IsTempName('.pja-tmp-1-1000', pid)
     and not IsTempName('.pja-tmp-0-0', pid) and not IsTempName('.pja-tmp-1-0x', pid) and not IsTempName('x.pja-tmp-1-0', pid)
     and not IsTempName('.pja-tmp1234', pid) and not IsTempName('.pja-tmp-a-0', pid) and not IsTempName('.pja-tmp-99999999999-0', pid),
     'anything else is not one');

  Writeln('--- leftovers of an interrupted run: noticed, deleted only when asked');
  { 4294967295 is no process's pid, here or on Windows }
  dead := '.pja-tmp-4294967295-';
  d := TempDir('left');
  PutOld(d + '/' + dead + '0', 2 * LEFTOVER_AGE);
  PutOld(d + '/' + dead + '1', 60);                         { fresh: may still be written }
  PutOld(d + '/' + TempName(9), 2 * LEFTOVER_AGE);          { a live process's: this one }
  PutOld(d + '/.pja-tmp-x', 2 * LEFTOVER_AGE);               { not the pattern }
  note := CheckLeftovers(d + '/out.jpg', False);
  Check(Pos('found 1 leftover temporary', note) > 0, 'one found: ' + note);
  Check(Exists(d + '/' + dead + '0'), '  and without asking, nothing deleted');
  Check(CheckLeftovers(d + '/other.jpg', False) = '', '  each directory once per run');
  d := TempDir('left_clean');
  PutOld(d + '/' + dead + '0', 2 * LEFTOVER_AGE);
  PutOld(d + '/.pja-tmp3', 2 * LEFTOVER_AGE);
  PutOld(d + '/' + dead + '1', 60);
  PutOld(d + '/' + TempName(9), 2 * LEFTOVER_AGE);
  PutOld(d + '/.pja-tmp-x', 2 * LEFTOVER_AGE);
  ForceDirectories(d + '/' + dead + '2');
  FileSetDate(d + '/' + dead + '2', DateTimeToFileDate(Now - 2 * LEFTOVER_AGE / 86400));
  {$ifndef MSWINDOWS}
  PutText(d + '/victim', 'kept');
  MakeLink(d + '/victim', d + '/' + dead + '3');
  {$endif}
  note := CheckLeftovers(d + '/out.jpg', True);
  Check(Pos('deleted 2 leftover temporaries', note) > 0, 'asked: an old one of a dead pid and an old-pattern one: ' + note);
  Check(not Exists(d + '/' + dead + '0') and not Exists(d + '/.pja-tmp3'), '  both gone');
  Check(Exists(d + '/' + dead + '1') and Exists(d + '/' + TempName(9)) and Exists(d + '/.pja-tmp-x'),
     '  a fresh one, a live process''s and another name stay');
  Check(DirectoryExists(d + '/' + dead + '2'), '  a directory with the name stays');
  {$ifndef MSWINDOWS}
  Check(IsLink(d + '/' + dead + '3') and (ReadText(d + '/victim') = 'kept'), '  a link with the name stays, its target too');
  {$endif}

  { --- Defects measured on 2026-10-09 in the previous Rust version. }
  {$ifndef MSWINDOWS}
  Writeln('--- final_link_pointing_outside_is_not_followed_when_overwriting');
  d := TempDir('final_outside'); outside := TempDir('final_outside_x');
  PutText(outside + '/victim.txt', 'original');
  MakeLink(outside + '/victim.txt', d + '/a.jpg');
  f := WriteVerified(d + '/a.jpg', B('new'), H16('new'), omDelete, False, oc);
  Check(not f.Ok, 'without overwrite: the link takes the name, ' + f.Text);
  Check(ReadText(outside + '/victim.txt') = 'original', '  outside intact');
  f := WriteVerified(d + '/a.jpg', B('new'), H16('new'), omDelete, True, oc);
  Check(f.Ok and (oc.kind = ocVerified), 'with overwrite: Verified');
  Check(ReadText(outside + '/victim.txt') = 'original', '  outside intact');
  Check(not IsLink(d + '/a.jpg'), '  the link was replaced');
  Check(ReadText(d + '/a.jpg') = 'new', '  with the new contents');

  Writeln('--- a_dangling_link_takes_the_name');
  d := TempDir('dangling'); outside := TempDir('dangling_x');
  MakeLink(outside + '/new.txt', d + '/b.jpg');
  f := WriteVerified(d + '/b.jpg', B('x'), H16('x'), omDelete, False, oc);
  Check((not f.Ok) and (f.code = ESysEEXIST), 'Io(EEXIST), ' + f.Text);
  Check(not Exists(outside + '/new.txt'), 'nothing was created outside');

  Writeln('--- a_hard_link_is_not_written_through');
  d := TempDir('hard'); outside := TempDir('hard_x');
  PutText(outside + '/victim.txt', 'original');
  if fpLink(PChar(outside + '/victim.txt'), PChar(d + '/c.jpg')) <> 0 then raise Exception.Create('link');
  f := WriteVerified(d + '/c.jpg', B('new'), H16('new'), omDelete, True, oc);
  Check(f.Ok, 'writes');
  Check(ReadText(outside + '/victim.txt') = 'original', 'outside intact');

  Writeln('--- a name near NAME_MAX: the temporary is short, not <name>.pja-tmpN');
  d := TempDir('long');
  q := StringOfChar('n', 250) + '.jpg';
  f := WriteVerified(d + '/' + q, B('l'), H16('l'), omDelete, False, oc);
  Check(f.Ok and (ReadText(d + '/' + q) = 'l'), 'without overwrite: ' + f.Text);
  f := WriteVerified(d + '/' + q, B('m'), H16('m'), omDelete, True, oc);
  Check(f.Ok and (ReadText(d + '/' + q) = 'm'), 'with overwrite: ' + f.Text);
  f := WriteVerified(d + '/' + q, B('k'), H16('other'), omKeep, False, oc);
  Check(f.Ok and (oc.kind = ocKept) and (oc.path = d + '/pja.corrupt') and (ReadText(d + '/pja.corrupt') = 'k'),
     'keep: <name>.corrupt is too long, pja.corrupt beside it');
  Check(not Exists(d + '/' + TempName(0)), 'no temporary left');

  Writeln('--- corrupt_name_taken_by_a_dangling_link');
  d := TempDir('corrupt_link');
  MakeLink(d + '/does_not_exist', d + '/g.jpg.corrupt');
  f := WriteVerified(d + '/g.jpg', B('x'), H16('other'), omKeep, False, oc);
  Check(f.Ok and (ExtractFileName(oc.path) = 'g.jpg.corrupt.1'), 'goes to .corrupt.1');
  Check(IsLink(d + '/g.jpg.corrupt'), 'the link is still there');
  {$endif}

  { a declared array and not `for n in [...]`: with literals, FPC trims them to the length of the first }
  for i := 0 to High(TEMP_DIRS) do DeleteTree(IncludeTrailingPathDelimiter(TMP) + 'pjafs_' + TEMP_DIRS[i]);

  Writeln;
  Writeln(cells, ' cells, ', failures, ' failures');
  {$ifdef MSWINDOWS} if (failures > 0) or (cells < 44) then Halt(1);
  {$else} if (failures > 0) or (cells < 62) then Halt(1); {$endif}
end.
