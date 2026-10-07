unit RetroTune.Binary;

interface

uses
  System.SysUtils;

procedure RequireBytes(const Data: TBytes; Offset, Count: Integer);

function LE16(const Data: TBytes; Offset: Integer): Word;

function LE32(const Data: TBytes; Offset: Integer): Cardinal;

function TextField(const Data: TBytes; Offset, Count: Integer): string;

procedure ValidateRender(Available, Frames, Channels: Integer);

implementation

procedure RequireBytes(const Data: TBytes; Offset, Count: Integer);
begin
  if (Offset < 0) or (Count < 0) or (Offset > Length(Data)) or (Count > Length(Data) - Offset) then
    raise EArgumentException.Create('Truncated music file');
end;

function LE16(const Data: TBytes; Offset: Integer): Word;
begin
  RequireBytes(Data, Offset, 2);
  Result := Data[Offset] or (Word(Data[Offset + 1]) shl 8);
end;

function LE32(const Data: TBytes; Offset: Integer): Cardinal;
begin
  RequireBytes(Data, Offset, 4);
  Result := Cardinal(LE16(Data, Offset)) or (Cardinal(LE16(Data, Offset + 2)) shl 16);
end;

function TextField(const Data: TBytes; Offset, Count: Integer): string;
begin
  RequireBytes(Data, Offset, Count);
  var N := 0;
  while (N < Count) and (Data[Offset + N] <> 0) do
    Inc(N);
  try
    Result := TEncoding.UTF8.GetString(Data, Offset, N).Trim;
  except
    on E: EEncodingError do
    begin
      // Legacy tracker titles can use an eight-bit Cyrillic code page.
      var Legacy := TEncoding.GetEncoding(1251);
      try
        Result := Legacy.GetString(Data, Offset, N).Trim;
      finally
        Legacy.Free;
      end;
    end;
  end;
end;

procedure ValidateRender(Available, Frames, Channels: Integer);
begin
  if (Frames < 0) or (Frames > 4096) or (Channels < 1) or (Frames > Available div Channels) then
    raise EArgumentOutOfRangeException.Create('Invalid PCM frame count (maximum 4096)');
end;

end.

