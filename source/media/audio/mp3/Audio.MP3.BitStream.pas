unit Audio.MP3.BitStream;

{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes;

type
  TMP3BitStream = class
  private
    FData: TBytes;
    FBytePos: Int64;
    FBitPos: Integer;   // bit position within current byte (7=MSB, 0=LSB)
    FDataLen: Int64;
    function GetBitsLeft: Int64;
  public
    constructor Create(const Data: TBytes; Offset: Integer = 0); overload;
    constructor Create(Stream: TStream); overload;

    function ReadBits(N: Integer): Cardinal;
    function PeekBits(N: Integer): Cardinal;
    procedure SkipBits(N: Integer);

    function GetByte: Byte;
    function BitsAvailable: Int64;
    procedure SetPosition(BytePos: Int64; BitOfs: Integer = 7);

    property BitsLeft: Int64 read GetBitsLeft;
    property BytePosition: Int64 read FBytePos;
    property BitPosition: Integer read FBitPos;
  end;

implementation

constructor TMP3BitStream.Create(const Data: TBytes; Offset: Integer);
begin
  inherited Create;
  FData := Data;
  FDataLen := Length(Data);
  FBytePos := Offset;
  FBitPos := 7;
end;

constructor TMP3BitStream.Create(Stream: TStream);
var
  Len: Int64;
begin
  inherited Create;
  Len := Stream.Size - Stream.Position;
  SetLength(FData, Len);
  if Len > 0 then
    Stream.ReadBuffer(FData[0], Len);
  FDataLen := Len;
  FBytePos := 0;
  FBitPos := 7;
end;

function TMP3BitStream.GetBitsLeft: Int64;
begin
  Result := BitsAvailable;
end;

function TMP3BitStream.BitsAvailable: Int64;
begin
  if FBytePos >= FDataLen then
    Result := 0
  else
    Result := (FDataLen - FBytePos - 1) * 8 + (FBitPos + 1);
end;

procedure TMP3BitStream.SetPosition(BytePos: Int64; BitOfs: Integer);
begin
  FBytePos := BytePos;
  FBitPos := BitOfs;
end;

function TMP3BitStream.GetByte: Byte;
begin
  if FBytePos >= FDataLen then
    Result := 0
  else
  begin
    Result := FData[FBytePos];
    Inc(FBytePos);
  end;
end;

function TMP3BitStream.ReadBits(N: Integer): Cardinal;
var
  Result64: Cardinal;
  BitsRemain: Integer;
  CurByte: Byte;
  BitsFromByte: Integer;
begin
  Result64 := 0;
  BitsRemain := N;

  while BitsRemain > 0 do
  begin
    if FBytePos >= FDataLen then
    begin
      // Return what we have, shift left for remaining bits
      Result64 := Result64 shl BitsRemain;
      Break;
    end;

    CurByte := FData[FBytePos];
    // How many bits available in this byte?
    BitsFromByte := FBitPos + 1; // bits available in current byte

    if BitsRemain >= BitsFromByte then
    begin
      // Take all remaining bits from this byte
      Result64 := (Result64 shl BitsFromByte) or Cardinal(CurByte and ((1 shl BitsFromByte) - 1));
      Dec(BitsRemain, BitsFromByte);
      Inc(FBytePos);
      FBitPos := 7;
    end
    else
    begin
      // Take only BitsRemain bits from this byte
      // They are at positions FBitPos down to (FBitPos - BitsRemain + 1)
      Result64 := (Result64 shl BitsRemain) or
        Cardinal((CurByte shr (FBitPos - BitsRemain + 1)) and ((1 shl BitsRemain) - 1));
      Dec(FBitPos, BitsRemain);
      BitsRemain := 0;
    end;
  end;

  Result := Result64;
end;

function TMP3BitStream.PeekBits(N: Integer): Cardinal;
var
  SaveBytePos: Int64;
  SaveBitPos: Integer;
begin
  SaveBytePos := FBytePos;
  SaveBitPos := FBitPos;
  Result := ReadBits(N);
  FBytePos := SaveBytePos;
  FBitPos := SaveBitPos;
end;

procedure TMP3BitStream.SkipBits(N: Integer);
var
  TotalBits: Int64;
  NewBit: Int64;
begin
  TotalBits := (FBytePos * 8) + (7 - FBitPos) + N;
  FBytePos := TotalBits div 8;
  NewBit := TotalBits mod 8;
  FBitPos := 7 - Integer(NewBit);
  if FBytePos > FDataLen then
    FBytePos := FDataLen;
end;

end.

