{ The segments zpaq-std hands to the plugin's ZPAQL decoder, for the test of
  that decoder (tools/zpaql/test_pjadec.py): for each JPEG, <out dir>/<name>.seg,
  the original size (u32 LE) and the stream of the full model, and
  <name>.args, the $3 the plugin's query gives for it (pjazpaqlargs). For a
  JPEG-LS file, the same for the pjals codec's decoder.

    zpaql_segments <out dir> <jpeg> ...
    zpaql_segments --pjax <out dir> <jpeg> ...   the pjax codec's streams
    zpaql_segments --pjall <out dir> <jpeg> ...  the pjall codec's (lossless JPEG) }
program zpaql_segments;

{$mode objfpc}{$H+}

uses {$ifdef unix}cthreads,{$endif} SysUtils, Classes, pjajls, pjacodec, pjazpaqlargs;

var data, stream, seg: TBytes; f: TFileStream; i, first: Integer; name, outDir: string; t: Text; pjax, pjall: Boolean;
begin
  pjax := ParamStr(1) = '--pjax';
  pjall := ParamStr(1) = '--pjall';
  first := 2; outDir := ParamStr(1);
  if pjax or pjall then begin first := 3; outDir := ParamStr(2); end;
  for i := first to ParamCount do begin
    f := TFileStream.Create(ParamStr(i), fmOpenRead or fmShareDenyNone);
    try
      data := nil; SetLength(data, f.Size);
      if f.Size > 0 then f.ReadBuffer(data[0], f.Size);
    finally f.Free; end;
    if (pjax and not CompressPjax(data, stream, True, 1).Ok) or
       (not pjax and not Compress(data, stream, False, 1, False, False).Ok) then begin
      WriteLn(StdErr, ParamStr(i), ': not compressed'); Halt(1);
    end;
    seg := nil; SetLength(seg, 4 + Length(stream));
    seg[0] := Length(data) and 255; seg[1] := (Length(data) shr 8) and 255;
    seg[2] := (Length(data) shr 16) and 255; seg[3] := (Length(data) shr 24) and 255;
    Move(stream[0], seg[4], Length(stream));
    name := ChangeFileExt(ExtractFileName(ParamStr(i)), '.seg');
    f := TFileStream.Create(IncludeTrailingPathDelimiter(outDir) + name, fmCreate);
    try f.WriteBuffer(seg[0], Length(seg)); finally f.Free; end;
    Assign(t, IncludeTrailingPathDelimiter(outDir) + ChangeFileExt(name, '.args'));
    Rewrite(t);
    if pjax then WriteLn(t, ZpaqlPjaxArgs(stream))
    else if pjall then WriteLn(t, ZpaqlLjpegArgs(stream))
    else if IsJls(data) then WriteLn(t, ZpaqlJlsArgs(stream)) else WriteLn(t, ZpaqlArgs(stream));
    Close(t);
  end;
end.
