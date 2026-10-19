{ Writes the compressed stream of each JPEG of a directory into another, as
  <name>.pjc. For the differential between builds: the reference (checked,
  Pascal) and the fast one (PJA_FAST, with and without asm) have to write
  the same bytes.

    dump_streams <jpeg dir> <out dir> [threads] }
program dump_streams;
{$I ../pja.inc}
uses {$ifdef unix} cthreads, {$endif} SysUtils, Classes, pjacodec;
var sr: TSearchRec; s: TFileStream; d, st: TBytes; o: string; threads: Integer;
begin
  threads := StrToIntDef(ParamStr(3), 1);
  if FindFirst(ParamStr(1) + '/*', faAnyFile, sr) = 0 then repeat
    if (sr.Attr and faDirectory) <> 0 then Continue;
    s := TFileStream.Create(ParamStr(1) + '/' + sr.Name, fmOpenRead or fmShareDenyNone);
    SetLength(d, s.Size); if s.Size > 0 then s.ReadBuffer(d[0], s.Size); s.Free;
    if Compress(d, st, False, threads).Ok then begin
      o := ParamStr(2) + '/' + sr.Name + '.pjc';
      s := TFileStream.Create(o, fmCreate); s.WriteBuffer(st[0], Length(st)); s.Free;
    end;
  until FindNext(sr) <> 0;
end.
