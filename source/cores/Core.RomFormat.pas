unit Core.RomFormat;

interface

uses
  System.Classes, System.SysUtils;

type
  TRomSystem = (Unknown, NES, GB, GBC, MD);

  TRomEncoding = (Native, SMD, ByteSwapped);

  TRomFormatInfo = record
    System: TRomSystem;
    Encoding: TRomEncoding;
    function SystemId: string;
  end;

function DetectRom(const Data: TBytes): TRomFormatInfo; overload;

function DetectRom(Stream: TStream): TRomFormatInfo; overload;

function ReadRomData(Stream: TStream): TBytes;

function NormalizeRom(const Data: TBytes; const Format: TRomFormatInfo): TBytes;

implementation

function TRomFormatInfo.SystemId: string;
begin
  case System of
    TRomSystem.NES:
      Result := 'nes';
    TRomSystem.GB:
      Result := 'gb';
    TRomSystem.GBC:
      Result := 'gbc';
    TRomSystem.MD:
      Result := 'md';
  else
    Result := '';
  end;
end;

function DetectRom(const Data: TBytes): TRomFormatInfo;
const
  Logo: array[0..47] of Byte = ($CE, $ED, $66, $66, $CC, $0D, $00, $0B, $03, $73, $00, $83,
    $00, $0C, $00, $0D, $00, $08, $11, $1F, $88, $89, $00, $0E, $DC, $CC, $6E, $E6, $DD, $DD,
    $D9, $99, $BB, $BB, $67, $63, $6E, $0E, $EC, $CC, $DD, $DC, $99, $9F, $BB, $B9, $33, $3E);

  function Signature(Offset: Integer; const Text: AnsiString): Boolean;
  begin
    Result := (Length(Data) >= Offset + Length(Text)) and
      CompareMem(@Data[Offset], PAnsiChar(Text), Length(Text));
  end;

begin
  Result := Default(TRomFormatInfo);
  if Signature(0, 'NES' + #$1A) then
    Result.System := TRomSystem.NES
  else if (Length(Data) >= $150) and CompareMem(@Data[$104], @Logo[0], SizeOf(Logo)) then
  begin
    if Data[$143] in [$80, $C0] then
      Result.System := TRomSystem.GBC
    else
      Result.System := TRomSystem.GB;
  end
  else if Signature($100, 'SEGA') or Signature($200, 'SEGA') then
    Result.System := TRomSystem.MD
  else if Signature($100, 'ESAG') or Signature($200, 'ESAG') then
  begin
    Result.System := TRomSystem.MD;
    Result.Encoding := TRomEncoding.ByteSwapped;
  end
  else if (Length(Data) >= $4200) and
    (Data[512 + $2000 + $80] = Ord('S')) and (Data[512 + $80] = Ord('E')) and
    (Data[512 + $2000 + $81] = Ord('G')) and (Data[512 + $81] = Ord('A')) then
  begin
    Result.System := TRomSystem.MD;
    Result.Encoding := TRomEncoding.SMD;
  end;
end;

function DetectRom(Stream: TStream): TRomFormatInfo;
begin
  if Stream = nil then
    raise EArgumentNilException.Create('Stream');
  var Position := Stream.Position;
  try
    var Data: TBytes;
    SetLength(Data, $4200);
    var Count := 0;
    while Count < Length(Data) do
    begin
      var Read := Stream.Read(Data[Count], Length(Data) - Count);
      if Read = 0 then
        Break;
      Inc(Count, Read);
    end;
    SetLength(Data, Count);
    Result := DetectRom(Data);
  finally
    Stream.Position := Position;
  end;
end;

function ReadRomData(Stream: TStream): TBytes;
const
  MaxSize = 64 * 1024 * 1024;
begin
  if Stream = nil then
    raise EArgumentNilException.Create('Stream');
  var Buffer: array[0..65535] of Byte;
  var Memory := TMemoryStream.Create;
  try
    while True do
    begin
      var Count := Stream.Read(Buffer, SizeOf(Buffer));
      if Count = 0 then
        Break;
      if Memory.Size + Count > MaxSize then
        raise EReadError.Create('ROM exceeds 64 MiB');
      Memory.WriteBuffer(Buffer, Count);
    end;
    SetLength(Result, Memory.Size);
    if Length(Result) > 0 then
      Move(Memory.Memory^, Result[0], Length(Result));
  finally
    Memory.Free;
  end;
end;

function NormalizeRom(const Data: TBytes; const Format: TRomFormatInfo): TBytes;
begin
  Result := Copy(Data);
  if Format.Encoding = TRomEncoding.ByteSwapped then
  begin
    if Odd(Length(Result)) then
      raise EReadError.Create('Invalid byte-swapped ROM size');
    for var I := 0 to Length(Result) div 2 - 1 do
    begin
      Result[I * 2] := Data[I * 2 + 1];
      Result[I * 2 + 1] := Data[I * 2];
    end;
  end
  else if Format.Encoding = TRomEncoding.SMD then
  begin
    if ((Length(Data) - 512) mod $4000 <> 0) then
      raise EReadError.Create('Invalid SMD size');
    SetLength(Result, Length(Data) - 512);
    for var Block := 0 to Length(Result) div $4000 - 1 do
      for var I := 0 to $1FFF do
      begin
        Result[Block * $4000 + I * 2] := Data[512 + Block * $4000 + $2000 + I];
        Result[Block * $4000 + I * 2 + 1] := Data[512 + Block * $4000 + I];
      end;
  end;
end;

end.

