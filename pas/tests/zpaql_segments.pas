{ The segments zpaq-std hands to the plugin's ZPAQL decoder, for the test of
  that decoder (tools/zpaql/test_pjadec.py): for each JPEG, <out dir>/<name>.seg,
  the original size (u32 LE) and the stream of the full model.

    zpaql_segments <out dir> <jpeg> ... }
program zpaql_segments;

{$mode objfpc}{$H+}

uses {$ifdef unix}cthreads,{$endif} SysUtils, Classes, pjacodec;

var data, stream, seg: TBytes; f: TFileStream; i: Integer; name: string;
begin
  for i := 2 to ParamCount do begin
    f := TFileStream.Create(ParamStr(i), fmOpenRead or fmShareDenyNone);
    try
      data := nil; SetLength(data, f.Size);
      if f.Size > 0 then f.ReadBuffer(data[0], f.Size);
    finally f.Free; end;
    if not Compress(data, stream, False, 1, False).Ok then begin
      WriteLn(StdErr, ParamStr(i), ': not compressed'); Halt(1);
    end;
    seg := nil; SetLength(seg, 4 + Length(stream));
    seg[0] := Length(data) and 255; seg[1] := (Length(data) shr 8) and 255;
    seg[2] := (Length(data) shr 16) and 255; seg[3] := (Length(data) shr 24) and 255;
    Move(stream[0], seg[4], Length(stream));
    name := ChangeFileExt(ExtractFileName(ParamStr(i)), '.seg');
    f := TFileStream.Create(IncludeTrailingPathDelimiter(ParamStr(1)) + name, fmCreate);
    try f.WriteBuffer(seg[0], Length(seg)); finally f.Free; end;
  end;
end.
